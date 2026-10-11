const rawUrl = process.argv[2] ?? process.env.ALICE_DEPLOYMENT_URL;
const expectedSha = process.env.ALICE_EXPECTED_SHA;

if (expectedSha !== undefined && !/^[0-9a-f]{40}$/i.test(expectedSha)) {
  console.error("ALICE_EXPECTED_SHA must be a full 40-character Git SHA");
  process.exitCode = 2;
} else if (!rawUrl) {
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
    !/^[a-zA-Z0-9._-]{1,32}$/.test(payload.release.version) ||
    payload.release.version !== headerVersion
  ) {
    throw new Error("Release metadata is missing or inconsistent");
  }
  if (
    expectedSha &&
    payload.release.version.toLowerCase() !==
      expectedSha.slice(0, 12).toLowerCase()
  ) {
    throw new Error("Release version does not match the expected Git commit");
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
