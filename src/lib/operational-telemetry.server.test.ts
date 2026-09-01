import { afterEach, describe, expect, it, vi } from "vitest";
import {
  consumeOperationalEventCapacity,
  observeApiRequest,
  recordOperationalEvent,
  resetOperationalEventCapacityForTest,
  serverRequestOutcome,
  shouldRecordServerRequest,
} from "./operational-telemetry.server";

afterEach(() => {
  resetOperationalEventCapacityForTest();
  vi.unstubAllEnvs();
});

describe("server operational telemetry", () => {
  it("adds reproducible timing and emits only the closed server contract", async () => {
    vi.stubEnv("VERCEL_GIT_COMMIT_SHA", "1234567890abcdef");
    const lines: string[] = [];
    const times = [10, 22.345];
    const handler = observeApiRequest(
      "/api/phone",
      () => Response.json({ ok: true }),
      {
        now: () => times.shift() ?? 22.345,
        random: () => 0,
        sink: (line) => lines.push(line),
      },
    );
    const response = await handler({
      request: new Request("https://alice.example/api/phone"),
    });

    expect(response.headers.get("server-timing")).toBe("alice;dur=12.35");
    await expect(response.json()).resolves.toEqual({ ok: true });
    expect(JSON.parse(lines[0] ?? "{}")).toEqual({
      type: "alice_operational",
      version: "1234567890ab",
      kind: "server_request",
      route: "/api/phone",
      method: "GET",
      status: 200,
      outcome: "ok",
      latencyMs: 12.35,
    });
    expect(lines[0]).not.toContain("alice.example");
  });

  it("always records failures and rethrows without logging error details", async () => {
    const lines: string[] = [];
    const handler = observeApiRequest(
      "/api/sync",
      () => {
        throw new Error("private database detail");
      },
      { now: () => 1, random: () => 1, sink: (line) => lines.push(line) },
    );
    await expect(
      handler({
        request: new Request("https://alice.example/api/sync", {
          method: "POST",
        }),
      }),
    ).rejects.toThrow("private database detail");
    expect(JSON.parse(lines[0] ?? "{}")).toMatchObject({
      route: "/api/sync",
      method: "POST",
      status: 500,
      outcome: "server_error",
    });
    expect(lines[0]).not.toContain("private database detail");
  });

  it("samples successes but never samples away HTTP errors", () => {
    expect(shouldRecordServerRequest(200, () => 0.09)).toBe(true);
    expect(shouldRecordServerRequest(200, () => 0.1)).toBe(false);
    expect(shouldRecordServerRequest(502, () => 1)).toBe(true);
    expect(serverRequestOutcome(400)).toBe("bad_request");
    expect(serverRequestOutcome(401)).toBe("unauthorized");
    expect(serverRequestOutcome(429)).toBe("rate_limited");
    expect(serverRequestOutcome(502)).toBe("upstream_error");
  });

  it("can attach timing without recursively recording the ingestion route", async () => {
    const lines: string[] = [];
    const handler = observeApiRequest(
      "/api/telemetry",
      () => new Response(null, { status: 429 }),
      {
        now: () => 1,
        sink: (line) => lines.push(line),
        record: false,
      },
    );
    const response = await handler({
      request: new Request("https://alice.example/api/telemetry", {
        method: "POST",
      }),
    });
    expect(response.headers.get("server-timing")).toBe("alice;dur=0");
    expect(lines).toEqual([]);
  });

  it("bounds anonymous ingestion per runtime window", () => {
    for (let index = 0; index < 600; index += 1) {
      expect(consumeOperationalEventCapacity(1_000)).toBe(true);
    }
    expect(consumeOperationalEventCapacity(1_000)).toBe(false);
    expect(consumeOperationalEventCapacity(61_000)).toBe(true);
  });

  it("does not emit production logs in development by default", () => {
    vi.stubEnv("NODE_ENV", "development");
    const spy = vi.spyOn(console, "info").mockImplementation(() => undefined);
    recordOperationalEvent({
      kind: "client_error",
      route: "/",
      browser: "safari",
      viewport: "narrow",
      code: "runtime_error",
    });
    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
  });
});
