import { afterEach, describe, expect, it, vi } from "vitest";
import { streamHermesDirect } from "./hermes-direct";

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function sse(text: string) {
  return new Response(
    `data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}\n\ndata: [DONE]\n\n`,
    { status: 200, headers: { "Content-Type": "text/event-stream" } },
  );
}

afterEach(() => vi.unstubAllGlobals());

async function collect(
  fetchMock: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>,
) {
  vi.stubGlobal("fetch", vi.fn(fetchMock));
  const events = [];
  for await (const event of streamHermesDirect({
    url: "http://127.0.0.1:8642",
    key: "12345678",
    model: "chosen-model",
    provider: "chosen-provider",
    messages: [{ role: "user", content: "hello" }],
    signal: AbortSignal.timeout(1_000),
  })) {
    events.push(event);
  }
  return events;
}

describe("direct chat model fallback", () => {
  it.each([
    [401, { detail: "unauthorized" }],
    [429, { detail: "usage_limit_reached" }],
    [503, { detail: "provider overloaded" }],
  ])("does not change model or retry on status %s", async (status, body) => {
    let calls = 0;
    const events = await collect(async () => {
      calls += 1;
      return json(status, body);
    });

    expect(calls).toBe(1);
    expect(events.some((event) => event.type === "model-fallback")).toBe(false);
    expect(events.at(-1)?.type).toBe("error");
  });

  it("retries only an identified incompatibility and announces the switch", async () => {
    const bodies: Array<Record<string, unknown>> = [];
    let calls = 0;
    const events = await collect(async (_input, init) => {
      calls += 1;
      bodies.push(JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>);
      return calls === 1
        ? json(404, { error: { message: "model_not_found" } })
        : sse("fallback reply");
    });

    expect(calls).toBe(2);
    expect(bodies[1]).toMatchObject({ model: "hermes-agent", stream: true });
    expect(bodies[1]?.provider).toBeUndefined();
    expect(events[0]).toEqual({
      type: "model-fallback",
      requestedModel: "chosen-model",
      requestedProvider: "chosen-provider",
      model: "hermes-agent",
      reason: "incompatible",
    });
    expect(events).toContainEqual({ type: "delta", text: "fallback reply" });
  });
});
