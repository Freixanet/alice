import { describe, expect, it, vi } from "vitest";
import { streamHermesSessionChat } from "./hermes-session-chat-transport";

describe("Hermes session chat transport", () => {
  it("posts only the new multimodal turn to the negotiated session endpoint", async () => {
    const fetcher = vi.fn(
      async (_input: string | URL, _init?: RequestInit) =>
        new Response(
          [
            'event: run.started\ndata: {"run_id":"run_1"}\n',
            'event: assistant.delta\ndata: {"run_id":"run_1","delta":"Hello"}\n',
            'event: assistant.completed\ndata: {"run_id":"run_1","content":"Hello"}\n',
            'event: run.completed\ndata: {"run_id":"run_1"}\n',
          ].join("\n"),
          { status: 200, headers: { "Content-Type": "text/event-stream" } },
        ),
    );
    const events = [];
    for await (const event of streamHermesSessionChat({
      fetch: fetcher,
      base: "https://hermes.example",
      token: "secret",
      sessionId: "session / one",
      message: [
        { type: "text", text: "Look" },
        { type: "image_url", image_url: { url: "data:image/png;base64,AA==" } },
      ],
      conversationId: "alice-1",
      model: "model-1",
      provider: "provider-1",
      signal: new AbortController().signal,
    })) {
      events.push(event);
    }

    expect(fetcher).toHaveBeenCalledOnce();
    const [url, init] = fetcher.mock.calls[0]!;
    expect(url).toBe(
      "https://hermes.example/api/sessions/session%20%2F%20one/chat/stream",
    );
    expect(JSON.parse(String(init?.body))).toEqual({
      message: [
        { type: "text", text: "Look" },
        { type: "image_url", image_url: { url: "data:image/png;base64,AA==" } },
      ],
      model: "model-1",
      provider: "provider-1",
    });
    expect(init?.headers).toMatchObject({
      Authorization: "Bearer secret",
      "X-Hermes-Session-Token": "secret",
      "X-Hermes-Session-Key": "alice-1",
    });
    expect(events).toEqual([
      { type: "run", runId: "run_1", status: "running" },
      { type: "delta", text: "Hello" },
      { type: "run", runId: "run_1", status: "completed" },
    ]);
  });

  it("uses the completed response when Hermes emitted no deltas", async () => {
    const fetcher = vi.fn(
      async (_input: string | URL, _init?: RequestInit) =>
        new Response(
          'event: assistant.completed\ndata: {"run_id":"run_2","content":"Complete"}\n\n',
          { status: 200 },
        ),
    );
    const events = [];
    for await (const event of streamHermesSessionChat({
      fetch: fetcher,
      base: "https://hermes.example",
      token: "secret",
      sessionId: "session-2",
      message: "Hi",
      signal: new AbortController().signal,
    })) {
      events.push(event);
    }
    expect(events).toEqual([{ type: "delta", text: "Complete" }]);
  });

  it("returns a bounded upstream error", async () => {
    const fetcher = vi.fn(async (_input: string | URL, _init?: RequestInit) =>
      Response.json({ error: { message: "Session missing" } }, { status: 404 }),
    );
    const events = [];
    for await (const event of streamHermesSessionChat({
      fetch: fetcher,
      base: "https://hermes.example",
      token: "secret",
      sessionId: "missing",
      message: "Hi",
      signal: new AbortController().signal,
    })) {
      events.push(event);
    }
    expect(events).toEqual([{ type: "error", message: "Session missing" }]);
  });
});
