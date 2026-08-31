import { afterEach, describe, expect, it, vi } from "vitest";
import { useHermes } from "./store";
import {
  listHermesLive,
  mutateHermes,
  readHermesProfiles,
  readHermesProfileSoul,
  readHermesSessionMessages,
} from "./hermes-live";

const livePayload = {
  ok: true as const,
  writable: true,
  owner: false,
  local: false,
  skills: [],
  toolsets: [],
  mcp: [],
  cron: [],
  cronDeliveryTargets: [],
  channels: [],
  sessions: [],
  pairing: [],
  pairingApproved: [],
  webhooks: { enabled: false, subscriptions: [] },
  projects: [],
  curator: null,
};

function response(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Hermes profile-aware proxy client", () => {
  it("scopes live reads and mutations only after exact negotiation", async () => {
    useHermes.setState({
      gatewayPlace: "cloud",
      profile: "research",
      gatewayMeta: {
        model: "hermes-agent",
        mode: "proxy",
        probedAt: Date.now(),
        manifest: {
          version: "0.21.0",
          compatibility: "current",
          capabilities: { profiles: true },
          advertised: ["profiles"],
        },
      },
    });
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(response(livePayload))
      .mockResolvedValueOnce(response({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    expect(await listHermesLive()).toEqual(livePayload);
    expect(
      await mutateHermes({
        action: "toggle-skill",
        name: "browser",
        enabled: true,
      }),
    ).toEqual({ ok: true });

    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({
      action: "live",
      profile: "research",
    });
    expect(JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body))).toEqual({
      action: "mutate",
      profile: "research",
      mutation: { action: "toggle-skill", name: "browser", enabled: true },
    });
  });

  it("parses profiles, SOUL and session messages through closed actions", async () => {
    useHermes.setState({ gatewayPlace: "cloud", profile: "research" });
    const profiles = {
      ok: true as const,
      state: {
        active: "default",
        current: "default",
        profiles: [],
      },
    };
    const soul = { ok: true as const, content: "Be rigorous.", exists: true };
    const messages = {
      ok: true as const,
      sessionId: "session-1",
      messages: [],
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(response(profiles))
      .mockResolvedValueOnce(response(soul))
      .mockResolvedValueOnce(response(messages));
    vi.stubGlobal("fetch", fetchMock);

    expect(await readHermesProfiles()).toEqual(profiles);
    expect(await readHermesProfileSoul({ name: "research" })).toEqual(soul);
    expect(await readHermesSessionMessages({ sessionId: "session-1" })).toEqual(
      messages,
    );
  });
});
