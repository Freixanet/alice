import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useHermes } from "./store";
import { clearHermesModelCache } from "./hermes-model-cache";
import {
  controlHermesRunClient,
  getHermesRun,
  listHermesModels,
  probeGateway,
  setHermesModel,
} from "./hermes-client";

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

beforeEach(() => {
  clearHermesModelCache();
  useHermes.setState({
    gatewayPlace: "cloud",
    gatewayUrl: "https://hermes.example",
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
});

afterEach(() => {
  clearHermesModelCache();
  vi.unstubAllGlobals();
});

describe("Hermes proxy client actions", () => {
  it("deduplicates model reads without coupling caller cancellation", async () => {
    let resolve!: (response: Response) => void;
    const fetchMock = vi.fn(
      (_input: RequestInfo | URL, _init?: RequestInit) =>
        new Promise<Response>((done) => (resolve = done)),
    );
    vi.stubGlobal("fetch", fetchMock);
    const controller = new AbortController();
    const first = listHermesModels({
      refresh: true,
      signal: controller.signal,
    });
    const second = listHermesModels({ refresh: true });
    await Promise.resolve();
    await Promise.resolve();
    expect(fetchMock).toHaveBeenCalledOnce();
    controller.abort();
    expect(
      (fetchMock.mock.calls[0]?.[1] as RequestInit | undefined)?.signal
        ?.aborted,
    ).toBe(false);
    resolve(json({ ok: true, models: [] }));
    await expect(first).resolves.toEqual({ ok: false, models: [] });
    await expect(second).resolves.toMatchObject({ ok: true, models: [] });
  });

  it("covers connection, model listing and model assignment contracts", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        json({ ok: true, model: "hermes-agent", mode: "proxy" }),
      )
      .mockResolvedValueOnce(
        json({
          ok: true,
          models: [{ id: "gpt-5.6", label: "GPT 5.6", provider: "openai" }],
          currentModel: "gpt-5.6",
          currentProvider: "openai",
        }),
      )
      .mockResolvedValueOnce(json({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    expect(
      await probeGateway({
        url: "https://hermes.example",
        key: "12345678",
        place: "cloud",
        save: true,
      }),
    ).toMatchObject({ ok: true, model: "hermes-agent" });
    expect(await listHermesModels()).toMatchObject({
      ok: true,
      currentModel: "gpt-5.6",
    });
    expect(
      await setHermesModel({
        url: "https://hermes.example",
        place: "cloud",
        model: "gpt-5.6",
        provider: "openai",
      }),
    ).toEqual({ ok: true });
    expect(
      JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)),
    ).toMatchObject({ action: "models", profile: "research" });
    expect(
      JSON.parse(String(fetchMock.mock.calls[2]?.[1]?.body)),
    ).toMatchObject({ action: "set-model", profile: "research" });
  });

  it("scopes run recovery and control to the negotiated profile", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        json({ ok: true, run: { runId: "run-1", status: "running" } }),
      )
      .mockResolvedValueOnce(json({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    expect(
      await getHermesRun({
        runId: "run-1",
        conversationId: "chat-1",
        signal: AbortSignal.timeout(1_000),
      }),
    ).toMatchObject({ runId: "run-1", status: "running" });
    expect(
      await controlHermesRunClient({ action: "stop", runId: "run-1" }),
    ).toBe(true);
    expect(
      JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body)),
    ).toMatchObject({ profile: "research" });
    expect(
      JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)),
    ).toMatchObject({ profile: "research" });
  });
});
