/**
 * Native Google / Apple OAuth (this app's Better Auth — not the Grok broker).
 *
 * Set env vars; never commit secrets. Google: `GOOGLE_CLIENT_ID` +
 * `GOOGLE_CLIENT_SECRET`. Apple: `APPLE_CLIENT_ID` and either
 * `APPLE_CLIENT_SECRET` (JWT) or `APPLE_TEAM_ID` + `APPLE_KEY_ID` +
 * `APPLE_PRIVATE_KEY` (PKCS8, `\n` ok). Optional `APPLE_APP_BUNDLE_IDENTIFIER`.
 *
 * Redirect URIs to register:
 *   http://localhost:8080/api/auth/callback/google
 *   http://localhost:8080/api/auth/callback/apple
 *   https://<magicdns>.ts.net/api/auth/callback/google  (Tailscale Serve / phone)
 */
import { SignJWT, importPKCS8 } from "jose";

const env = (key: string): string | undefined => {
  const value = process.env[key]?.trim();
  return value ? value : undefined;
};

export const googleNativeEnabled = Boolean(
  env("GOOGLE_CLIENT_ID") && env("GOOGLE_CLIENT_SECRET"),
);

export const appleNativeEnabled = Boolean(
  env("APPLE_CLIENT_ID") &&
  (env("APPLE_CLIENT_SECRET") ||
    (env("APPLE_TEAM_ID") && env("APPLE_KEY_ID") && env("APPLE_PRIVATE_KEY"))),
);

export const nativeSocialEnabled = googleNativeEnabled || appleNativeEnabled;

const appleSecretRef = globalThis as typeof globalThis & {
  __aliceAppleClientSecret__?: string;
};

async function appleClientSecret(): Promise<string> {
  const ready = env("APPLE_CLIENT_SECRET");
  if (ready) return ready;
  if (appleSecretRef.__aliceAppleClientSecret__)
    return appleSecretRef.__aliceAppleClientSecret__;
  const clientId = env("APPLE_CLIENT_ID");
  const teamId = env("APPLE_TEAM_ID");
  const keyId = env("APPLE_KEY_ID");
  const pem = env("APPLE_PRIVATE_KEY")?.replace(/\\n/g, "\n");
  if (!clientId || !teamId || !keyId || !pem) {
    throw new Error(
      "Apple Sign In is missing APPLE_CLIENT_ID / TEAM_ID / KEY_ID / PRIVATE_KEY.",
    );
  }
  const key = await importPKCS8(pem, "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .setExpirationTime("180d")
    .setAudience("https://appleid.apple.com")
    .setSubject(clientId)
    .sign(key);
  appleSecretRef.__aliceAppleClientSecret__ = jwt;
  return jwt;
}

export function nativeSocialProviders() {
  const google = googleNativeEnabled
    ? {
        google: {
          clientId: env("GOOGLE_CLIENT_ID") as string,
          clientSecret: env("GOOGLE_CLIENT_SECRET") as string,
          prompt: "select_account" as const,
        },
      }
    : {};
  const apple = appleNativeEnabled
    ? {
        apple: async () => ({
          clientId: env("APPLE_CLIENT_ID") as string,
          clientSecret: await appleClientSecret(),
          appBundleIdentifier: env("APPLE_APP_BUNDLE_IDENTIFIER"),
        }),
      }
    : {};
  const socialProviders = { ...google, ...apple };
  return Object.keys(socialProviders).length ? socialProviders : undefined;
}
