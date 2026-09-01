import { expect, test } from "@playwright/test";

test("normal API handler p95 stays below 100 ms", async ({
  request,
}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium");

  for (let warmup = 0; warmup < 3; warmup += 1) {
    await request.get("/api/phone");
  }

  const durations: number[] = [];
  for (let sample = 0; sample < 30; sample += 1) {
    const response = await request.get("/api/phone");
    expect(response.ok()).toBe(true);
    const timing = response.headers()["server-timing"] ?? "";
    const duration = Number(/alice;dur=([\d.]+)/.exec(timing)?.[1]);
    expect(Number.isFinite(duration), timing).toBe(true);
    durations.push(duration);
  }

  durations.sort((left, right) => left - right);
  const p95 = durations[Math.ceil(durations.length * 0.95) - 1] ?? Infinity;
  expect(p95, `Alice handler p95: ${p95} ms`).toBeLessThan(100);
});

test("telemetry ingestion accepts only the anonymous contract", async ({
  request,
}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium");
  const safe = {
    kind: "client_error",
    route: "/skills",
    browser: "safari",
    viewport: "narrow",
    code: "runtime_error",
  };
  const accepted = await request.post("/api/telemetry", { data: safe });
  expect(accepted.status()).toBe(204);
  expect(accepted.headers()["server-timing"]).toMatch(/^alice;dur=[\d.]+$/);

  const rejected = await request.post("/api/telemetry", {
    data: { ...safe, message: "private error detail" },
  });
  expect(rejected.status()).toBe(400);
  await expect(rejected.json()).resolves.toEqual({
    ok: false,
    error: { code: "invalid_request" },
  });
});
