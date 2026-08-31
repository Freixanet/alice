import { describe, expect, it, vi } from "vitest";
import {
  createDirectHermesTransport,
  createProxyHermesTransport,
  type HermesDirectTransportContext,
  type HermesTransportOperation,
} from "./hermes-transport";

type TestResult = { ok: true; source: "direct" | "proxy" };

function operation(
  scope: "global" | "profile",
): HermesTransportOperation<TestResult> {
  return {
    scope,
    proxy: { action: "diagnostics" },
    direct: async () => ({ ok: true, source: "direct" }),
    decodeProxy: () => ({ ok: true, source: "proxy" }),
  };
}

describe("HermesTransport", () => {
  it("keeps the direct key inside the adapter and scopes negotiated profiles", async () => {
    const direct = vi.fn(async (_context: HermesDirectTransportContext) => {
      return { ok: true, source: "direct" } as const;
    });
    const transport = createDirectHermesTransport({
      url: "http://127.0.0.1:8642",
      key: "never-serialize-this",
      profile: "research",
    });

    await transport.execute({ ...operation("profile"), direct });
    await transport.execute({ ...operation("global"), direct });

    expect(transport.kind).toBe("direct");
    expect(Object.keys(transport)).toEqual(["kind", "execute"]);
    expect(direct.mock.calls[0]?.[0]).toEqual({
      url: "http://127.0.0.1:8642",
      key: "never-serialize-this",
      profile: "research",
    });
    expect(direct.mock.calls[1]?.[0]).toEqual({
      url: "http://127.0.0.1:8642",
      key: "never-serialize-this",
    });
  });

  it("adds profiles only to scoped proxy operations and never sends a key", async () => {
    const fetcher = vi.fn<typeof fetch>(async () =>
      Promise.resolve(new Response(JSON.stringify({ ok: true }))),
    );
    const transport = createProxyHermesTransport({
      profile: "research",
      fetcher,
    });

    expect(await transport.execute(operation("profile"))).toEqual({
      ok: true,
      source: "proxy",
    });
    await transport.execute(operation("global"));

    const scoped = JSON.parse(
      String(fetcher.mock.calls[0]?.[1]?.body),
    ) as Record<string, unknown>;
    const global = JSON.parse(
      String(fetcher.mock.calls[1]?.[1]?.body),
    ) as Record<string, unknown>;
    expect(scoped).toEqual({ action: "diagnostics", profile: "research" });
    expect(global).toEqual({ action: "diagnostics" });
    expect(JSON.stringify([scoped, global])).not.toContain("key");
    expect(fetcher.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      cache: "no-store",
    });
  });
});
