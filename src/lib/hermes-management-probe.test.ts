import { describe, expect, it, vi } from "vitest";
import {
  discoverManagementCapabilities,
  missingManagementCapabilities,
  withDiscoveredManagement,
} from "./hermes-management-probe";

describe("management capability discovery", () => {
  it("enables a feature the agent manifest never mentioned", async () => {
    // The exact case this exists for: a Hermes whose /v1/capabilities only
    // describes the chat surface, while /api/profiles works fine.
    const found = await discoverManagementCapabilities(
      missingManagementCapabilities({ "chat.runs": true }),
      async (path) =>
        path === "/api/profiles"
          ? { ok: true, status: 200 }
          : { ok: false, status: 404 },
    );
    expect(found).toEqual(["profiles"]);
  });

  it("never probes what the manifest already advertises", async () => {
    const probe = vi.fn(async () => ({ ok: true, status: 200 }));
    await discoverManagementCapabilities(
      missingManagementCapabilities({
        profiles: true,
        insights: true,
        cron: true,
        mcp: true,
        webhooks: true,
        projects: true,
      }),
      probe,
    );
    expect(probe).not.toHaveBeenCalled();
  });

  it("treats a login redirect as unsupported, not as available", async () => {
    const found = await discoverManagementCapabilities(
      missingManagementCapabilities({}),
      async () => ({ ok: false, status: 302 }),
    );
    expect(found).toEqual([]);
  });

  it("survives a management surface that throws", async () => {
    const found = await discoverManagementCapabilities(
      missingManagementCapabilities({}),
      async (path) => {
        if (path === "/api/cron/jobs") throw new Error("ECONNREFUSED");
        return path === "/api/webhooks"
          ? { ok: true, status: 200 }
          : { ok: false, status: 404 };
      },
    );
    expect(found).toEqual(["webhooks"]);
  });

  it("returns a stable order however the probes resolve", async () => {
    const found = await discoverManagementCapabilities(
      missingManagementCapabilities({}),
      async (path) => {
        const slow = path === "/api/profiles";
        if (slow) await new Promise((r) => setTimeout(r, 5));
        return { ok: true, status: 200 };
      },
    );
    expect(found).toEqual([
      "profiles",
      "insights",
      "cron",
      "mcp",
      "webhooks",
      "projects",
    ]);
  });

  it("runs at most two probes at a time", async () => {
    let inFlight = 0;
    let peak = 0;
    await discoverManagementCapabilities(
      missingManagementCapabilities({}),
      async () => {
        inFlight += 1;
        peak = Math.max(peak, inFlight);
        await new Promise((r) => setTimeout(r, 2));
        inFlight -= 1;
        return { ok: false, status: 404 };
      },
    );
    expect(peak).toBeLessThanOrEqual(2);
  });
});

describe("folding discovery into a manifest", () => {
  const base = {
    version: "0.21.0",
    normalizedVersion: "0.21.0",
    compatibility: "current" as const,
    advertised: ["chat_completions"],
    capabilities: { "chat.runs": true } as Record<string, boolean>,
  };

  it("adds only what answered, and marks where it came from", async () => {
    const merged = await withDiscoveredManagement(base, async (path) =>
      path === "/api/profiles"
        ? { ok: true, status: 200 }
        : { ok: false, status: 404 },
    );
    expect(merged?.capabilities.profiles).toBe(true);
    expect(merged?.capabilities.insights).toBeUndefined();
    expect(merged?.capabilities["chat.runs"]).toBe(true);
    expect(merged?.advertised).toContain("profiles:probed");
  });

  it("leaves the manifest untouched when nothing answers", async () => {
    const merged = await withDiscoveredManagement(base, async () => ({
      ok: false,
      status: 404,
    }));
    expect(merged).toBe(base);
  });

  it("keeps the connection alive when probing blows up", async () => {
    const merged = await withDiscoveredManagement(base, () => {
      throw new Error("network down");
    });
    expect(merged).toBe(base);
  });

  it("passes an absent manifest straight through", async () => {
    expect(
      await withDiscoveredManagement(undefined, async () => ({
        ok: true,
        status: 200,
      })),
    ).toBeUndefined();
  });
});
