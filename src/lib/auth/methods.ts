import type { SocialProviderId } from "./client";

/** Public provider names only. Never serialize provider configuration. */
export function configuredSignInMethods(
  env: Record<string, string | undefined>,
): SocialProviderId[] {
  const has = (name: string) => Boolean(env[name]?.trim());
  if (env.VITE_AUTH_ENABLED?.trim() === "false") return [];
  const broker =
    !env.VERCEL &&
    ((has("GROK_AUTH_CLIENT_ID") && has("GROK_AUTH_CLIENT_SECRET")) ||
      has("GROK_PREVIEW_CLIENT_SECRET"));
  const methods: SocialProviderId[] = [];
  if (broker || (has("GOOGLE_CLIENT_ID") && has("GOOGLE_CLIENT_SECRET")))
    methods.push("google");
  if (
    broker ||
    (has("APPLE_CLIENT_ID") &&
      (has("APPLE_CLIENT_SECRET") ||
        (has("APPLE_TEAM_ID") &&
          has("APPLE_KEY_ID") &&
          has("APPLE_PRIVATE_KEY"))))
  )
    methods.push("apple");
  return methods;
}
