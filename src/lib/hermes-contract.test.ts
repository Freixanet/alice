import { describe, expect, it, vi } from "vitest";
import { HERMES_CONTRACT_FIXTURES } from "./hermes-contract-fixtures";
import { verifyLiveHermesContract } from "./hermes-contract-verifier";
import {
  HERMES_CURRENT_STABLE,
  HERMES_PREVIOUS_STABLE,
  parseHermesCapabilityManifest,
} from "./gateway-contracts";

const requiredEndpoints = {
  health: ["GET", "/health"],
  health_detailed: ["GET", "/health/detailed"],
  models: ["GET", "/v1/models"],
  model_options: ["GET", "/api/model/options"],
  chat_completions: ["POST", "/v1/chat/completions"],
  runs: ["POST", "/v1/runs"],
  run_status: ["GET", "/v1/runs/{run_id}"],
  run_events: ["GET", "/v1/runs/{run_id}/events"],
  run_approval: ["POST", "/v1/runs/{run_id}/approval"],
  run_steer: ["POST", "/v1/runs/{run_id}/steer"],
  run_stop: ["POST", "/v1/runs/{run_id}/stop"],
  skills: ["GET", "/v1/skills"],
  toolsets: ["GET", "/v1/toolsets"],
  sessions: ["GET", "/api/sessions"],
  session_messages: ["GET", "/api/sessions/{session_id}/messages"],
  session_fork: ["POST", "/api/sessions/{session_id}/fork"],
  session_chat_stream: ["POST", "/api/sessions/{session_id}/chat/stream"],
} as const;

describe("pinned Hermes release contracts", () => {
  it("tracks exactly the current and previous official package versions", () => {
    expect(
      HERMES_CONTRACT_FIXTURES.map((fixture) => fixture.source.tag),
    ).toEqual(["v2026.8.31", "v2026.8.27"]);
    expect(
      HERMES_CONTRACT_FIXTURES.map((fixture) => fixture.source.packageVersion),
    ).toEqual([HERMES_CURRENT_STABLE, HERMES_PREVIOUS_STABLE]);
    for (const fixture of HERMES_CONTRACT_FIXTURES) {
      expect(fixture.source.commit).toMatch(/^[a-f0-9]{40}$/);
      expect(fixture.source.apiServerSource).toContain(fixture.source.tag);
    }
  });

  it.each(HERMES_CONTRACT_FIXTURES)(
    "$source.packageVersion advertises every Alice transport primitive",
    (fixture) => {
      const manifest = parseHermesCapabilityManifest(fixture.capabilities);
      expect(manifest.compatibility).not.toBe("unknown");
      expect(manifest.capabilities).toMatchObject({
        "chat.streaming": true,
        "chat.runs": true,
        "chat.cancel": true,
        "chat.steer": true,
        "chat.approvals": true,
        models: true,
        skills: true,
        toolsets: true,
        sessions: true,
        diagnostics: true,
      });
      const endpoints = fixture.capabilities.endpoints as Record<
        string,
        { method?: unknown; path?: unknown }
      >;
      for (const [name, [method, path]] of Object.entries(requiredEndpoints)) {
        expect(endpoints[name], name).toEqual({ method, path });
      }
    },
  );

  it("negotiates durable run idempotency only where Hermes advertises it", () => {
    const [current, previous] = HERMES_CONTRACT_FIXTURES.map((fixture) =>
      parseHermesCapabilityManifest(fixture.capabilities),
    );
    expect(current?.capabilities["chat.run_idempotency"]).toBe(true);
    expect(previous?.capabilities["chat.run_idempotency"]).toBeUndefined();
  });
});

describe("live Hermes contract verifier", () => {
  it("checks only bounded, read-only endpoints and returns no secret", async () => {
    const current = HERMES_CONTRACT_FIXTURES[0];
    const fetcher = vi.fn<typeof fetch>(async (input) => {
      const path = new URL(String(input)).pathname;
      const payload =
        path === "/health/detailed"
          ? { status: "ready", version: HERMES_CURRENT_STABLE }
          : path === "/v1/capabilities"
            ? current.capabilities
            : path === "/v1/models"
              ? { data: [{ id: "hermes-agent" }] }
              : path === "/v1/skills"
                ? [{ name: "research" }]
                : [{ name: "web" }];
      return Response.json(payload);
    });
    const result = await verifyLiveHermesContract({
      url: "https://hermes.example",
      key: "never-return-this-key",
      fetcher,
    });

    expect(result).toMatchObject({
      ok: true,
      version: HERMES_CURRENT_STABLE,
      models: 1,
      skills: 1,
      toolsets: 1,
    });
    expect(JSON.stringify(result)).not.toContain("never-return-this-key");
    expect(fetcher).toHaveBeenCalledTimes(5);
    for (const [, init] of fetcher.mock.calls) {
      expect(init).toMatchObject({ cache: "no-store", redirect: "manual" });
    }
  });

  it("fails closed for an unversioned or unsupported Hermes", async () => {
    const result = await verifyLiveHermesContract({
      url: "https://hermes.example",
      key: "never-return-this-key",
      fetcher: async (input) => {
        const path = new URL(String(input)).pathname;
        return Response.json(
          path === "/health/detailed"
            ? { status: "ready", version: "99.0.0" }
            : HERMES_CONTRACT_FIXTURES[0].capabilities,
        );
      },
    });
    expect(result).toEqual({
      ok: false,
      error: "Hermes 99.0.0 is outside Alice’s supported version window.",
    });
  });
});

const liveUrl = process.env.HERMES_LIVE_URL?.trim();
const liveKey = process.env.HERMES_LIVE_KEY?.trim();
const liveRequired = process.env.HERMES_LIVE_REQUIRED === "true";
const liveIt = liveUrl && liveKey ? it : it.skip;

if (liveRequired && (!liveUrl || !liveKey)) {
  it("requires explicit live Hermes credentials", () => {
    throw new Error(
      "Set HERMES_LIVE_URL and HERMES_LIVE_KEY to run the live contract gate.",
    );
  });
}

liveIt("matches a real supported Hermes without mutating it", async () => {
  const result = await verifyLiveHermesContract({
    url: liveUrl!,
    key: liveKey!,
  });
  expect(result).toMatchObject({ ok: true });
});
