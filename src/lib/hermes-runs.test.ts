import fc from "fast-check";
import { describe, expect, it } from "vitest";
import {
  buildHermesRunRequest,
  eventsFromHermesRunValue,
  parseHermesRunSnapshot,
  parseHermesRunStart,
} from "./hermes-runs";

describe("Hermes runs contract", () => {
  it("builds a run from the last user turn without duplicating it", () => {
    expect(
      buildHermesRunRequest({
        messages: [
          { role: "user", content: "first" },
          { role: "assistant", content: "answer" },
          { role: "user", content: "next" },
        ],
        conversationId: "chat-1",
        model: "model-1",
      }),
    ).toEqual({
      input: "next",
      conversation_history: [
        { role: "user", content: "first" },
        { role: "assistant", content: "answer" },
      ],
      session_id: "chat-1",
      model: "model-1",
    });
  });

  it("parses start, terminal state, deltas and approvals", () => {
    expect(parseHermesRunStart({ run_id: "run-1", status: "started" })).toEqual(
      {
        runId: "run-1",
        status: "started",
      },
    );
    expect(
      eventsFromHermesRunValue({
        event: "message.delta",
        run_id: "run-1",
        delta: "Hello",
      }),
    ).toEqual([{ type: "delta", text: "Hello" }]);
    expect(
      eventsFromHermesRunValue({
        event: "message.delta",
        run_id: "run-1",
        delta: " world",
      }),
    ).toEqual([{ type: "delta", text: " world" }]);
    expect(
      eventsFromHermesRunValue({
        event: "approval.request",
        run_id: "run-1",
        tool: "terminal",
        command: "npm test",
        choices: ["once", "always", "invalid", "deny"],
      }),
    ).toEqual([
      { type: "run", runId: "run-1", status: "waiting_for_approval" },
      {
        type: "approval",
        runId: "run-1",
        title: "terminal",
        command: "npm test",
        choices: ["once", "always", "deny"],
      },
    ]);
    expect(
      parseHermesRunSnapshot({
        run_id: "run-1",
        status: "completed",
        output: "Done",
      }),
    ).toEqual({ runId: "run-1", status: "completed", output: "Done" });
  });

  it("never throws or emits unbounded data for arbitrary remote JSON", () => {
    fc.assert(
      fc.property(fc.jsonValue(), (value) => {
        const events = eventsFromHermesRunValue(value);
        expect(events.length).toBeLessThanOrEqual(2);
        expect(() => JSON.stringify(events)).not.toThrow();
      }),
      { numRuns: 10_000 },
    );
  });
});
