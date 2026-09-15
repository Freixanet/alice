type Environment = Record<string, string | undefined>;

/** Validate before opening a database or minting production sessions. */
export function assertProductionConfiguration(env: Environment): void {
  if (env.NODE_ENV !== "production" && !env.VERCEL) return;
  if (
    !env.BETTER_AUTH_SECRET?.trim() ||
    env.BETTER_AUTH_SECRET.trim().length < 32
  ) {
    throw new Error(
      "Production requires BETTER_AUTH_SECRET with at least 32 characters.",
    );
  }
  if (env.VITE_AUTH_ENABLED?.trim() === "false") {
    throw new Error(
      "Production requires authentication; remove VITE_AUTH_ENABLED=false.",
    );
  }
  if (!env.DATABASE_URL?.trim()) {
    throw new Error(
      "Production requires DATABASE_URL; the local development database is not a deployment fallback.",
    );
  }
}
