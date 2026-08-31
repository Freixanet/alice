import { afterEach, describe, expect, it, vi } from "vitest";
import {
  listHermesLiveDirect,
  mutateHermesDirect,
  controlHermesRunDirect,
  getHermesRunDirect,
  readHermesProfilesDirect,
  readHermesProfileSoulDirect,
  streamHermesDirect,
  streamHermesSessionDirect,
} from "./hermes-direct";

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

afterEach(() => vi.unstubAllGlobals());

describe("Hermes direct profile transport", () => {
  it("parses only the safe profile projection and SOUL content", async () => {
    const fetchMock = vi.fn((input: string | URL) => {
      const url = String(input);
      if (url.endsWith("/api/profiles/active")) {
        return Promise.resolve(
          json({ active: "research", current: "default" }),
        );
      }
      if (url.endsWith("/api/profiles")) {
        return Promise.resolve(
          json({
            profiles: [
              {
                name: "research",
                display_name: "Research",
                path: "/must/not/reach/alice",
              },
            ],
          }),
        );
      }
      return Promise.resolve(json({ content: "Be rigorous.", exists: true }));
    });
    vi.stubGlobal("fetch", fetchMock);

    const profiles = await readHermesProfilesDirect({
      url: "http://127.0.0.1:8642",
      key: "12345678",
    });
    expect(profiles).toMatchObject({
      ok: true,
      state: { active: "research", current: "default" },
    });
    expect(JSON.stringify(profiles)).not.toContain("/must/not/reach/alice");
    expect(
      await readHermesProfileSoulDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        name: "research",
      }),
    ).toEqual({ ok: true, content: "Be rigorous.", exists: true });
  });

  it("adds the selected profile to every supported management read", async () => {
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL) => {
        seen.push(String(input));
        return Promise.resolve(json({}));
      }),
    );

    const result = await listHermesLiveDirect({
      url: "http://127.0.0.1:8642",
      key: "12345678",
      profile: "research",
    });
    expect(result.ok).toBe(true);
    expect(seen).toHaveLength(11);
    expect(seen.every((url) => /[?&]profile=research(?:&|$)/.test(url))).toBe(
      true,
    );
  });

  it("scopes ordinary writes and leaves profile lifecycle routes global", async () => {
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL) => {
        seen.push(String(input));
        return Promise.resolve(json({ ok: true }));
      }),
    );
    expect(
      await mutateHermesDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "research",
        action: "toggle-skill",
        name: "browser",
        enabled: true,
      }),
    ).toEqual({ ok: true });
    expect(
      await mutateHermesDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "research",
        action: "profile-activate",
        name: "research",
      }),
    ).toEqual({ ok: true });
    expect(seen[0]).toContain("/api/skills/toggle?profile=research");
    expect(seen[1]).toMatch(/\/api\/profiles\/active$/);
  });

  it("scopes chat, persisted chat and run control with the multiplex prefix", async () => {
    const seen: string[] = [];
    const sse = (payload: string) =>
      new Response(`data: ${payload}\n\ndata: [DONE]\n\n`, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL) => {
        const url = String(input);
        seen.push(url);
        if (url.includes("/v1/chat/completions")) {
          return Promise.resolve(
            sse(JSON.stringify({ choices: [{ delta: { content: "Hello" } }] })),
          );
        }
        if (url.includes("/chat/stream")) {
          return Promise.resolve(
            sse(
              JSON.stringify({
                type: "assistant.completed",
                content: "Stored hello",
              }),
            ),
          );
        }
        if (url.endsWith("/v1/runs/run-1")) {
          return Promise.resolve(json({ run_id: "run-1", status: "running" }));
        }
        return Promise.resolve(json({ ok: true }));
      }),
    );

    const chat = [];
    for await (const event of streamHermesDirect({
      url: "http://127.0.0.1:8642",
      key: "12345678",
      profile: "research",
      messages: [{ role: "user", content: "Hello" }],
      signal: AbortSignal.timeout(1_000),
    })) {
      chat.push(event);
    }
    expect(chat).toContainEqual({ type: "delta", text: "Hello" });

    const stored = [];
    for await (const event of streamHermesSessionDirect({
      url: "http://127.0.0.1:8642",
      key: "12345678",
      profile: "research",
      sessionId: "session-1",
      message: "Continue",
      signal: AbortSignal.timeout(1_000),
    })) {
      stored.push(event);
    }
    expect(stored).toContainEqual({ type: "delta", text: "Stored hello" });
    expect(
      await getHermesRunDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "research",
        runId: "run-1",
        signal: AbortSignal.timeout(1_000),
      }),
    ).toMatchObject({ runId: "run-1", status: "running" });
    expect(
      await controlHermesRunDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "research",
        runId: "run-1",
        action: "stop",
        signal: AbortSignal.timeout(1_000),
      }),
    ).toBe(true);
    expect(seen.every((url) => url.includes("/p/research/"))).toBe(true);
  });
});
