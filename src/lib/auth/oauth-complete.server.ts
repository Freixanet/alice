import { createAuthMiddleware } from "better-auth/api";

/**
 * After Google/Apple Allow, Better Auth 302s to `/` with a session cookie.
 * Cursor's browser (and local http) often drop that cookie, so AppGate bounces
 * back to `/login`. Rewrite the callback to `/auth/complete?token=` with the
 * raw session token (same value email/password already stores as bearer).
 */
export function oauthCompleteRedirect() {
  return {
    id: "oauth-complete-redirect",
    hooks: {
      after: [
        {
          matcher(ctx: { path?: string }) {
            const path = ctx.path ?? "";
            return path === "/callback/:id" || path.startsWith("/callback/");
          },
          handler: createAuthMiddleware(async (ctx) => {
            const token = ctx.context.newSession?.session?.token;
            if (!token) {
              console.warn("[auth] OAuth callback had no new session", {
                path: ctx.path,
              });
              return;
            }
            console.info("[auth] handing session to /auth/complete");
            throw ctx.redirect(`/auth/complete?token=${encodeURIComponent(token)}`);
          }),
        },
      ],
    },
  };
}
