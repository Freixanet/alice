import { afterEach, describe, expect, it, vi } from "vitest";
import {
  listHermesLiveDirect,
  mutateHermesDirect,
  controlHermesRunDirect,
  getHermesRunDirect,
  listHermesModelsDirect,
  readHermesActionStatusDirect,
  readHermesMcpCatalogDirect,
  readHermesMcpOAuthDirect,
  readHermesMcpUsageDirect,
  readHermesProfilesDirect,
  readHermesProfileSoulDirect,
  readHermesSkillContentDirect,
  searchHermesSkillsHubDirect,
  streamHermesDirect,
  streamHermesSessionDirect,
  setHermesModelDirect,
  startHermesMcpOAuthDirect,
  testHermesMcpServerDirect,
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
    expect(seen).toHaveLength(12);
    expect(seen.some((url) => url.includes("/api/dashboard/plugins/hub"))).toBe(
      true,
    );
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

  it("scopes the Pantheon MCP catalog, health, OAuth and usage APIs", async () => {
    const seen: Array<{ url: string; method?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL, init?: RequestInit) => {
        const url = String(input);
        seen.push({ url, method: init?.method });
        if (url.includes("/api/mcp/catalog")) {
          return Promise.resolve(json({ entries: [] }));
        }
        if (url.includes("/test")) {
          return Promise.resolve(json({ ok: true, tools: [] }));
        }
        if (url.includes("/auth")) {
          return Promise.resolve(
            json({
              flow_id: "flow-1",
              server_name: "github",
              status: "authorization_required",
            }),
          );
        }
        if (url.includes("/api/mcp/oauth/flows/")) {
          return Promise.resolve(
            json({
              flow_id: "flow-1",
              server_name: "github",
              status: "approved",
            }),
          );
        }
        return Promise.resolve(json({ tools: [] }));
      }),
    );

    const base = {
      url: "http://127.0.0.1:8642",
      key: "12345678",
      profile: "research",
    };
    expect(await readHermesMcpCatalogDirect(base)).toMatchObject({ ok: true });
    expect(
      await testHermesMcpServerDirect({ ...base, name: "github" }),
    ).toMatchObject({ ok: true });
    expect(
      await startHermesMcpOAuthDirect({ ...base, name: "github" }),
    ).toMatchObject({ ok: true });
    expect(
      await readHermesMcpOAuthDirect({ ...base, flowId: "flow-1" }),
    ).toMatchObject({ ok: true, flow: { status: "approved" } });
    expect(await readHermesMcpUsageDirect(base)).toEqual({
      ok: true,
      calls: {},
    });
    expect(
      seen.every(({ url }) => /[?&]profile=research(?:&|$)/.test(url)),
    ).toBe(true);
    expect(seen.filter(({ method }) => method === "POST")).toHaveLength(2);
  });

  it("creates Pantheon cron jobs atomically across the official two-step API", async () => {
    const calls: Array<{ url: string; method?: string; body?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL, init?: RequestInit) => {
        calls.push({
          url: String(input),
          method: init?.method,
          body: typeof init?.body === "string" ? init.body : undefined,
        });
        return Promise.resolve(
          String(input).includes("/api/cron/jobs?") && init?.method === "POST"
            ? json({ id: "pantheon-job" })
            : json({ ok: true }),
        );
      }),
    );

    await expect(
      mutateHermesDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "research",
        action: "cron-create",
        name: "Watch releases",
        prompt: "Report meaningful changes",
        schedule: "every 15m",
        continuity: true,
        monitorUrl: "https://example.com/releases",
        reasoningEffort: "high",
      }),
    ).resolves.toEqual({ ok: true, jobId: "pantheon-job" });

    expect(calls).toHaveLength(2);
    expect(calls[0]).toMatchObject({
      url: expect.stringContaining("/api/cron/jobs?profile=research"),
      method: "POST",
    });
    expect(JSON.parse(calls[0]?.body ?? "{}")).toMatchObject({
      context_from: ["self"],
    });
    expect(calls[1]).toMatchObject({
      url: expect.stringContaining(
        "/api/cron/jobs/pantheon-job?profile=research",
      ),
      method: "PUT",
    });
    expect(JSON.parse(calls[1]?.body ?? "{}")).toEqual({
      updates: {
        monitor_url: "https://example.com/releases",
        reasoning_effort: "high",
      },
    });
  });

  it("reads skill content and waits on background actions without exposing paths", async () => {
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL) => {
        const url = String(input);
        seen.push(url);
        if (url.includes("/api/skills/content")) {
          return Promise.resolve(
            json({
              name: "research",
              content: "---\nname: research\n---\nUse sources.",
              path: "/private/hermes/skills/research/SKILL.md",
            }),
          );
        }
        if (url.includes("/api/actions/skills-install/status")) {
          return Promise.resolve(
            json({
              name: "skills-install",
              running: false,
              exit_code: 0,
              lines: ["Installed"],
              cwd: "/private/hermes",
            }),
          );
        }
        if (url.includes("/api/skills/hub/search")) {
          return Promise.resolve(
            json({
              results: [
                {
                  identifier: "official/research/arxiv",
                  name: "arxiv",
                  description: "Search papers",
                },
              ],
            }),
          );
        }
        return Promise.resolve(
          json({ ok: true, name: "skills-install", pid: 321 }),
        );
      }),
    );

    expect(
      await readHermesSkillContentDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        name: "research",
        profile: "work",
      }),
    ).toEqual({
      ok: true,
      name: "research",
      content: "---\nname: research\n---\nUse sources.",
    });
    expect(
      await readHermesActionStatusDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        name: "skills-install",
        profile: "work",
      }),
    ).toEqual({
      ok: true,
      action: {
        name: "skills-install",
        running: false,
        exitCode: 0,
        lines: ["Installed"],
      },
    });
    expect(
      await mutateHermesDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "work",
        action: "skill-install",
        identifier: "official/research/arxiv",
      }),
    ).toEqual({ ok: true, actionName: "skills-install" });
    expect(
      await searchHermesSkillsHubDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        query: "papers",
        profile: "work",
      }),
    ).toEqual({
      ok: true,
      results: [
        {
          identifier: "official/research/arxiv",
          name: "arxiv",
          description: "Search papers",
          source: undefined,
          trust: undefined,
        },
      ],
    });
    expect(seen.every((url) => url.includes("profile=work"))).toBe(true);
  });

  it("scopes model discovery and default assignment to the selected profile", async () => {
    const seen: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: string | URL) => {
        const url = String(input);
        seen.push(url);
        if (url.includes("/v1/models")) {
          return Promise.resolve(
            json({
              data: [{ id: "gpt-5.6", provider: "openai" }],
              current_model: "gpt-5.6",
              current_provider: "openai",
            }),
          );
        }
        if (url.includes("/api/model/options")) {
          return Promise.resolve(
            json({
              providers: [
                {
                  id: "openai",
                  models: [{ id: "gpt-5.6" }],
                },
              ],
            }),
          );
        }
        return Promise.resolve(json({ ok: true }));
      }),
    );

    expect(
      await listHermesModelsDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "research",
      }),
    ).toMatchObject({ ok: true, currentModel: "gpt-5.6" });
    expect(
      await setHermesModelDirect({
        url: "http://127.0.0.1:8642",
        key: "12345678",
        profile: "research",
        model: "gpt-5.6",
        provider: "openai",
      }),
    ).toEqual({ ok: true });
    expect(seen[0]).toContain("/p/research/v1/models");
    expect(
      seen
        .filter((url) => url.includes("/api/model/options"))
        .every((url) => url.includes("profile=research")),
    ).toBe(true);
    expect(
      seen.some((url) => url.includes("/api/model/set?profile=research")),
    ).toBe(true);
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
