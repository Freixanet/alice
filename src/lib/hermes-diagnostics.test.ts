import { afterEach, describe, expect, it, vi } from "vitest";
import { readHermesDiagnosticsDirect } from "./hermes-direct";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Hermes diagnostics transport", () => {
  it("uses the exact authenticated endpoint and returns only safe fields", async () => {
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, _init?: RequestInit) =>
        new Response(
          JSON.stringify({
            status: "ready",
            version: "0.20.6",
            gateway_state: "running",
            active_agents: 1,
            gateway_busy: false,
            gateway_drainable: true,
            platforms: { telegram: { state: "connected", token: "secret" } },
            api_key: "secret",
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const result = await readHermesDiagnosticsDirect({
      url: "http://127.0.0.1:8642",
      key: "test-key-123",
    });

    expect(fetchMock).toHaveBeenCalledOnce();
    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "http://127.0.0.1:8642/health/detailed",
    );
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
      cache: "no-store",
      redirect: "manual",
      headers: expect.objectContaining({
        Authorization: "Bearer test-key-123",
      }),
    });
    expect(result).toMatchObject({
      ok: true,
      diagnostics: {
        status: "ready",
        version: "0.20.6",
        gatewayState: "running",
        activeAgents: 1,
        busy: false,
        drainable: true,
        platforms: [{ id: "telegram", name: "Telegram", status: "connected" }],
      },
    });
    expect(JSON.stringify(result)).not.toContain("secret");
  });

  it("fails closed when detailed health is unavailable", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("", { status: 404 })),
    );
    await expect(
      readHermesDiagnosticsDirect({
        url: "https://hermes.example.test",
        key: "test-key-123",
      }),
    ).resolves.toEqual({
      ok: false,
      error: "Couldn’t read Hermes diagnostics.",
    });
  });
});
