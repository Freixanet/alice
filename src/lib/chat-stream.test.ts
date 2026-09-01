import { describe, expect, it } from "vitest";
import {
  reduceChatStreamEvent,
  type ChatStreamAccumulator,
} from "./chat-stream";

describe("chat stream reducer", () => {
  it("reconciles deltas with an authoritative run result", () => {
    const state: ChatStreamAccumulator = { content: "", tools: [] };
    expect(
      reduceChatStreamEvent(state, { type: "delta", text: " Hello" }).patch,
    ).toMatchObject({ content: "Hello", pending: true });
    const completed = reduceChatStreamEvent(state, {
      type: "run",
      runId: "run-1",
      status: "completed",
      output: "Authoritative answer",
    });
    expect(completed).toMatchObject({
      patch: { content: "Authoritative answer", pending: false },
      activeRun: { runId: "run-1", terminal: true },
    });
    expect(state.content).toBe("Authoritative answer");
  });

  it("matches a completion to the latest running tool with the same name", () => {
    const state: ChatStreamAccumulator = { content: "", tools: [] };
    reduceChatStreamEvent(
      state,
      { type: "tool", name: "browser", status: "start" },
      () => "tool-1",
    );
    reduceChatStreamEvent(
      state,
      { type: "tool", name: "browser", status: "done" },
      () => "unused",
    );
    expect(state.tools).toEqual([
      { id: "tool-1", name: "browser", status: "done" },
    ]);
  });

  it("keeps an approval attached to its run", () => {
    const state: ChatStreamAccumulator = { content: "", tools: [] };
    const result = reduceChatStreamEvent(state, {
      type: "approval",
      runId: "run-2",
      title: "terminal",
      choices: ["once", "deny"],
    });
    expect(result.patch).toMatchObject({
      runId: "run-2",
      runStatus: "waiting_for_approval",
      pending: true,
    });
  });

  it("carries a model-limit classification onto the message", () => {
    const state: ChatStreamAccumulator = { content: "", tools: [] };
    const result = reduceChatStreamEvent(state, {
      type: "error",
      message: "You exceeded your current quota.",
      limit: { kind: "quota", retryAfterSeconds: 3600 },
    });
    expect(result.stop).toBe(true);
    expect(result.patch).toMatchObject({
      error: "You exceeded your current quota.",
      errorLimit: { kind: "quota", retryAfterSeconds: 3600 },
      pending: false,
    });
  });

  it("leaves errorLimit unset when the failure was not a limit", () => {
    const state: ChatStreamAccumulator = { content: "", tools: [] };
    const result = reduceChatStreamEvent(state, {
      type: "error",
      message: "Couldn’t connect.",
    });
    expect(result.patch).not.toHaveProperty("errorLimit");
  });
});
