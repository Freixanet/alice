import { describe, expect, it, vi } from "vitest";
import {
  controlHermesRun,
  startHermesRun,
  streamStartedHermesRun,
} from "./hermes-run-transport";

const base = "https://hermes.example";
const token = "a-valid-hermes-key";

describe("Hermes run transport", () => {
  it("starts a run and preserves structured SSE order", async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(
        Response.json({ run_id: "run-1", status: "started" }, { status: 202 }),
      )
      .mockResolvedValueOnce(
        new Response(
          [
            'data: {"event":"message.delta","run_id":"run-1","delta":"Hello"}',
            "",
            'data: {"event":"message.delta","run_id":"run-1","delta":" world"}',
            "",
            'data: {"event":"run.completed","run_id":"run-1","output":"Hello world"}',
            "",
          ].join("\n"),
          { headers: { "Content-Type": "text/event-stream" } },
        ),
      );
    const signal = new AbortController().signal;
    const started = await startHermesRun({
      fetch: fetcher,
      base,
      token,
      signal,
      messages: [{ role: "user", content: "Hi" }],
      conversationId: "chat-1",
    });
    expect(started.ok).toBe(true);
    if (!started.ok) return;

    const events = [];
    for await (const event of streamStartedHermesRun({
      fetch: fetcher,
      base,
      token,
      signal,
      run: started.run,
      conversationId: "chat-1",
    })) {
      events.push(event);
    }
    expect(events).toEqual([
      { type: "run", runId: "run-1", status: "started" },
      { type: "delta", text: "Hello" },
      { type: "delta", text: " world" },
      {
        type: "run",
        runId: "run-1",
        status: "completed",
        output: "Hello world",
      },
    ]);
  });

  it("recovers the authoritative output when an SSE stream closes early", async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(
          'data: {"event":"message.delta","run_id":"run-2","delta":"Part"}\n\n',
        ),
      )
      .mockResolvedValueOnce(
        Response.json({
          run_id: "run-2",
          status: "completed",
          output: "Part complete",
        }),
      );
    const events = [];
    for await (const event of streamStartedHermesRun({
      fetch: fetcher,
      base,
      token,
      signal: new AbortController().signal,
      run: { runId: "run-2", status: "started" },
    })) {
      events.push(event);
    }
    expect(events.at(-1)).toEqual({
      type: "run",
      runId: "run-2",
      status: "completed",
      output: "Part complete",
    });
  });

  it("sends approval choices only to the scoped run endpoint", async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValue(new Response(null, { status: 200 }));
    await expect(
      controlHermesRun({
        fetch: fetcher,
        base,
        token,
        signal: new AbortController().signal,
        action: "approval",
        runId: "run/unsafe",
        choice: "once",
      }),
    ).resolves.toBe(true);
    expect(fetcher).toHaveBeenCalledWith(
      `${base}/v1/runs/run%2Funsafe/approval`,
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ choice: "once", resolve_all: undefined }),
      }),
    );
  });

  it("sends bounded steering input to the scoped run endpoint", async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValue(new Response(null, { status: 200 }));
    await expect(
      controlHermesRun({
        fetch: fetcher,
        base,
        token,
        signal: new AbortController().signal,
        action: "steer",
        runId: "run-3",
        input: "Check the tests first",
      }),
    ).resolves.toBe(true);
    expect(fetcher).toHaveBeenCalledWith(
      `${base}/v1/runs/run-3/steer`,
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ input: "Check the tests first" }),
      }),
    );
  });
});
