const rawUrl = process.argv[2] ?? process.env.ALICE_DEPLOYMENT_URL;

if (!rawUrl) {
  console.error("Usage: npm run release:verify -- https://deployment.example");
  process.exitCode = 2;
} else {
  const origin = new URL(rawUrl).origin;
  const response = await fetch(`${origin}/api/status`, {
    headers: { Accept: "application/json" },
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(`Release check failed with HTTP ${response.status}`);
  }
  const payload = await response.json();
  const headerVersion = response.headers.get("x-alice-version");
  if (
    payload?.status !== "ok" ||
    typeof payload?.release?.version !== "string" ||
    payload.release.version !== headerVersion
  ) {
    throw new Error("Release metadata is missing or inconsistent");
  }
  console.info(
    JSON.stringify({
      status: "ok",
      version: payload.release.version,
      environment: payload.release.environment,
      source: payload.release.source,
    }),
  );
}
