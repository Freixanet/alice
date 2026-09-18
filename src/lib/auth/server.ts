/**
 * Server-only Better Auth for Alice, mounted at /api/auth/*.
 *
 * Email/password and configured native Google/Apple providers use Alice's
 * database. No shared secrets are shipped in source.
 * Production validates database, secret and authentication settings before boot.
 *
 * Client code must use ./client or ./use-current-user. Importing this module
 * into a browser bundle would pull in database and authentication internals.
 */
import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins";
import { tanstackStartCookies } from "better-auth/tanstack-start";
import { getCookie } from "@tanstack/react-start/server";
import { randomBytes } from "node:crypto";
import { assertProductionConfiguration } from "../deployment-config";
import { Pool } from "pg";
import { ensureDbReady, getPglite } from "../db";
import { emailAndPasswordEnabled } from "./email-password";
import { oauthCompleteRedirect } from "./oauth-complete.server";
import { nativeSocialEnabled, nativeSocialProviders } from "./social.server";
import { pgliteDialect } from "./pglite-dialect";

// Kick (and share) PGLite bootstrap as soon as the auth server module loads.
assertProductionConfiguration(process.env);
void ensureDbReady();

/**
 * Preview secret must outlive module reloads: PGLite (and its session rows) is
 * stored on `globalThis`, so an HMR re-eval of this file must NOT mint a new
 * signing secret or every existing session becomes invalid mid-dev. Process
 * restart clears both the secret and PGLite together.
 */
const globalAuthRef = globalThis as typeof globalThis & {
  __aliceAuthSecret__?: string;
};
function previewAuthSecret(): string {
  globalAuthRef.__aliceAuthSecret__ ??= randomBytes(32).toString("hex");
  return globalAuthRef.__aliceAuthSecret__;
}

/** Read an env var, treating empty/whitespace as unset. */
const env = (key: string): string | undefined => {
  const value = process.env[key]?.trim();
  return value ? value : undefined;
};

// Explicit off-switch. The deployer sets `VITE_AUTH_ENABLED=true` when it
// provisions auth; set it to "false" to force auth off everywhere (dev user).
const authDisabled = env("VITE_AUTH_ENABLED") === "false";

/** True when at least one sign-in method is active (real auth is enforced). */
export const authConfigured =
  !authDisabled && (emailAndPasswordEnabled || nativeSocialEnabled);

// This app's own Better Auth origin. When deployed the deployer injects the
// public URL. Otherwise we hand Better Auth a dynamic baseURL: it derives the
// origin per-request from the (proxied) host, validated against the allowlist
// (loopback + Tailscale), which makes the OAuth `redirect_uri` the concrete
// request origin.
function vercelHttpsOrigins(): string[] {
  const out: string[] = [];
  for (const raw of [
    env("VERCEL_PROJECT_PRODUCTION_URL"),
    env("VERCEL_URL"),
    env("VERCEL_BRANCH_URL"),
  ]) {
    if (!raw) continue;
    const host = raw.replace(/^https?:\/\//, "").replace(/\/+$/, "");
    if (host) out.push(`https://${host}`);
  }
  return [...new Set(out)];
}

const explicitBaseURL =
  env("BETTER_AUTH_URL")?.replace(/\/+$/, "") || vercelHttpsOrigins()[0];
// Local development. Browsers may send Origin as any of these for the same
// server — trusting only `localhost` rejects `127.0.0.1` and breaks
// email/password with "Invalid origin".
//
// The port is wildcarded on purpose: `npm run dev` defaults to 8080, but anyone
// running Alice may have that port taken and start elsewhere, and pinning the
// port made sign-in fail with a message that pointed nowhere near the cause.
// Loopback origins are reachable only from the machine itself, so widening the
// port adds no exposure.
const LOCAL_DEV_ORIGINS: string[] = [
  "http://localhost:*",
  "http://127.0.0.1:*",
  "http://[::1]:*",
];
const baseURL = explicitBaseURL ?? {
  allowedHosts: [
    "localhost",
    "127.0.0.1",
    "[::1]",
    // Tailscale Serve / MagicDNS (phone PWA). `*` matches dotted names.
    "*.ts.net",
  ],
  // `auto` → trust both http:// and https:// expansions of allowedHosts
  // (Tailscale is https; local dev is http).
  protocol: "auto" as const,
  fallback: "http://localhost:8080",
};

// Origins Better Auth accepts on credentialed POSTs (sign-up/sign-in, etc.).
// Missing entries here surface as FORBIDDEN "Invalid origin".
const trustedOrigins: string[] = [
  ...(explicitBaseURL
    ? [explicitBaseURL, ...LOCAL_DEV_ORIGINS]
    : [
        // Host wildcards (matched against Origin's host)
        "*.ts.net",
        // Full-origin wildcards (matched against Origin)
        "https://*.ts.net",
        "http://*.ts.net",
        ...LOCAL_DEV_ORIGINS,
      ]),
  ...vercelHttpsOrigins(),
  // Apple's form_post callback Origin for Sign in with Apple.
  "https://appleid.apple.com",
];

const databaseUrl = env("DATABASE_URL");

// Real Postgres when `DATABASE_URL` is set (deployed apps), else the app's
// embedded PGLite (preview) via a Kysely dialect — so Better Auth persists to the
// SAME DB as app data, including email/password users. Both use the Better Auth
// schema from `migrations/0001_auth.sql`.
const database = databaseUrl
  ? new Pool({
      connectionString: databaseUrl,
      max: process.env.VERCEL ? 1 : 10,
    })
  : { dialect: pgliteDialect(() => getPglite()), type: "postgres" as const };

// `__Host-` + Secure cookies are for HTTPS deployments. On local http they
// often never stick (Cursor's browser drops them), so Google Allow bounces
// back to /login with no session.
const localHttpAuth = !explicitBaseURL;

/** Session token cookie name. */
export const SESSION_TOKEN_COOKIE = localHttpAuth
  ? "alice.session_token"
  : "__Host-alice-auth.session_token";

const nativeSocial = nativeSocialProviders();

export const auth = betterAuth({
  baseURL,
  // Deployed apps inject BETTER_AUTH_SECRET. Preview: process-stable secret on
  // globalThis so HMR doesn't invalidate PGLite-backed sessions (see above).
  secret: env("BETTER_AUTH_SECRET") ?? previewAuthSecret(),
  database,

  // CSRF / origin check for credentialed auth POSTs (email sign-up/sign-in, …).
  // See `trustedOrigins` construction above — must cover live preview hosts AND
  // local loopback variants, or clients get "Invalid origin".
  trustedOrigins,

  // Encrypt OAuth tokens at rest and treat Google/Apple as trusted first-party
  // identities. Without this a login can fail with `account_not_linked` when
  // the upstream email is unverified.
  account: {
    encryptOAuthTokens: true,
    accountLinking: {
      enabled: true,
      trustedProviders: ["google", "apple"],
      // Owner may exist from email/password before the first Google sign-in;
      // same address must attach to that user, not mint a second identity.
      requireLocalEmailVerified: false,
      allowDifferentEmails: false,
    },
    storeStateStrategy: "database",
    // Cursor's local browser can drop the signed OAuth state cookie. Only the
    // local/preview path may rely on the database-backed state instead;
    // production always requires the state cookie as well.
    skipStateCookieCheck: localHttpAuth && !process.env.VERCEL,
  },

  // Cache the session in the short-lived signed `session_data` cookie so reads
  // (incl. the client's `/get-session`) skip the DB — this shrinks the "loading"
  // window and reduces auth flicker. See the `auth` skill for the full
  // flicker-prevention guidance (gate on `isPending`; SSR the session).
  session: { cookieCache: { enabled: true, maxAge: 300 } },

  // Local email/password — toggled only via `./email-password` (not a plugin).
  ...(emailAndPasswordEnabled ? { emailAndPassword: { enabled: true } } : {}),
  ...(nativeSocial ? { socialProviders: nativeSocial } : {}),

  // Local http: plain cookies so Google's callback can actually set a session.
  // Deployed: `__Host-` + Secure (no Domain) so a sibling app
  // cannot toss a shared-Domain cookie onto this origin.
  advanced: {
    // Tailscale Serve terminates TLS and forwards http://127.0.0.1:8080 with
    // X-Forwarded-Proto: https — Google OAuth redirect_uri must be that https origin.
    trustedProxyHeaders: !explicitBaseURL,
    useSecureCookies: !localHttpAuth,
    defaultCookieAttributes: localHttpAuth
      ? { secure: false, sameSite: "lax", path: "/" }
      : { secure: true, sameSite: "lax", path: "/" },
    cookies: {
      session_token: { name: SESSION_TOKEN_COOKIE },
      session_data: {
        name: localHttpAuth
          ? "alice.session_data"
          : "__Host-alice-auth.session_data",
      },
      account_data: {
        name: localHttpAuth
          ? "alice.account_data"
          : "__Host-alice-auth.account_data",
      },
      dont_remember: {
        name: localHttpAuth
          ? "alice.dont_remember"
          : "__Host-alice-auth.dont_remember",
      },
    },
  },

  plugins: [
    // Accept `Authorization: Bearer <session-token>` as an alternative to the
    // cookie. Needed when Set-Cookie doesn't survive the deployed social
    // bounce (see `oauthCompleteRedirect` below). The hook only fires when an
    // Authorization header is present, so the cookie path is unaffected.
    bearer(),

    // After social Allow, send the raw session token to `/auth/complete`
    // instead of relying on Set-Cookie (dropped in Cursor's browser / local http).
    oauthCompleteRedirect(),

    // Bridges Better Auth's Set-Cookie into TanStack Start responses. MUST be
    // last so it runs after every other plugin's hooks.
    tanstackStartCookies(),
  ],
});

export function readSessionToken(): string | null {
  return getCookie(SESSION_TOKEN_COOKIE) ?? null;
}
