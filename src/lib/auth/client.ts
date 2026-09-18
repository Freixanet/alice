import { genericOAuthClient } from "better-auth/client/plugins";
import { createAuthClient } from "better-auth/react";
import { runSignOut } from "../../../scripts/sign-out-plan.mjs";
import { LOGIN_SOCIAL } from "./providers";

/**
 * Better Auth client for this React SPA (browser-side).
 *
 * Talks to this app's OWN Better Auth at same-origin `/api/auth/*`. Deployed
 * social sign-in can drop SameSite cookies on the return navigation, so the
 * server hands out a bearer token (`/auth/complete`) that we keep in
 * sessionStorage; the `onRequest` hook attaches it when present. When cookies
 * work no token is stored, so nothing changes.
 *
 * To sign out call `signOut()` below, NOT `authClient.signOut()`: the raw call
 * leaves the bearer token in place, and `onRequest` keeps re-attaching it, so
 * the visitor stays signed in.
 */
export const authClient = createAuthClient({
  plugins: [genericOAuthClient()],
  fetchOptions: {
    credentials: "include",
    onRequest(ctx) {
      const token = getBearerToken();
      if (token) ctx.headers.set("Authorization", `Bearer ${token}`);
      return ctx;
    },
  },
});

/**
 * True when sign-in UI should be shown — i.e. whenever `VITE_AUTH_ENABLED` is
 * not `"false"`. `.alice/app-env.json` may set it to `"false"`, which selects
 * the dev user (see `use-current-user`); with the key removed, sign-in is real.
 */
export const authEnabled = import.meta.env.VITE_AUTH_ENABLED !== "false";

/** The upstream providers to render sign-in buttons for. */
export { LOGIN_SOCIAL };

// ── Bearer token ─────────────────────────────────────────────────────────────
// The deployed sign-in fallback can't rely on cookies surviving the OAuth
// bounce, so we keep the session's bearer token in sessionStorage and attach it
// to every Better Auth request (and to server functions, via
// `@/lib/auth/middleware`). Empty when the cookie path works.
const BEARER_KEY = "alice-auth.bearer-token";

/** The stored bearer token, or null. */
export function getBearerToken(): string | null {
  if (typeof window === "undefined") return null;
  try {
    return window.sessionStorage.getItem(BEARER_KEY);
  } catch {
    return null;
  }
}

export function setBearerToken(token: string | null): void {
  if (typeof window === "undefined") return;
  try {
    if (token) window.sessionStorage.setItem(BEARER_KEY, token);
    else window.sessionStorage.removeItem(BEARER_KEY);
  } catch {
    /* storage unavailable — ignore */
  }
}

export function authHeaders(extra?: HeadersInit): Headers {
  const headers = new Headers(extra);
  const token = getBearerToken();
  if (token && !headers.has("Authorization"))
    headers.set("Authorization", `Bearer ${token}`);
  return headers;
}

export type SocialProviderId = (typeof LOGIN_SOCIAL)[number]["id"];

/**
 * Google / Apple on `/login` via this app's native Better Auth social
 * providers (env credentials).
 */
export async function signInWithSocial(
  provider: SocialProviderId,
  opts: { callbackURL?: string; errorCallbackURL?: string } = {},
): Promise<void> {
  const callbackURL = opts.callbackURL ?? "/";
  const errorCallbackURL = opts.errorCallbackURL ?? "/login";
  if (!LOGIN_SOCIAL.some((p) => p.id === provider))
    throw new Error("Unknown provider");

  // Don't POST /sign-out first: on local http that race can wipe the OAuth
  // state before Google returns. Clear any leftover bearer; Google's
  // account picker is what switches identity.
  setBearerToken(null);

  const social = await authClient.signIn.social({
    provider,
    callbackURL,
    errorCallbackURL,
  });
  if (social.data && "token" in social.data && social.data.token) {
    setBearerToken(social.data.token);
  }
  if (social.data?.url) {
    window.location.href = social.data.url;
    return;
  }
  if (!social.error) {
    await authClient.getSession();
    if (typeof window !== "undefined") window.location.href = callbackURL;
    return;
  }
  throw new Error(social.error.message ?? "Sign-in failed");
}

/**
 * Sign out of THIS app's local session, clear the bearer token, then redirect.
 *
 * Use this, never `authClient.signOut()` — see the note on `authClient`.
 * Sequencing lives in `scripts/sign-out-plan.mjs` so it can be unit-tested.
 *
 * **Rejects if the server never confirms.** The session is an HttpOnly cookie
 * only the server can clear, so redirecting anyway would report a sign-out
 * that did not happen. `<UserButton />` handles that for you; a hand-rolled
 * control must catch it and let the visitor retry.
 */
export async function signOut(redirectTo = "/"): Promise<void> {
  await runSignOut({
    livePreview: false,
    hasBearer: Boolean(getBearerToken()),
    // Better Auth resolves with `{ error }` instead of rejecting, so surface a
    // failed response as a rejection for the sequence to act on.
    requestSignOut: async () => {
      const { error } = await authClient.signOut();
      if (error) throw new Error(error.message ?? "Sign-out failed");
    },
    clearToken: () => setBearerToken(null),
    redirect: () => {
      window.location.href = redirectTo;
    },
  });
}
