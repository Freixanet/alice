import { describe, expect, it } from "vitest";
import {
  reduceChatStreamEvent,
  type ChatStreamAccumulator,
} from "./chat-stream";

function accumulator(): ChatStreamAccumulator {
  return { content: "", tools: [] };
}

describe("chat model fallback metadata", () => {
  it("clears fallback metadata left by an earlier attempt when the retry uses the selected model", () => {
    const acc = accumulator();
    const result = reduceChatStreamEvent(acc, { type: "delta", text: "Hello" });

    expect(result.patch).toMatchObject({
      content: "Hello",
      pending: true,
      modelFallback: undefined,
    });
  });

  it("retains an announced fallback while its answer streams", () => {
    const acc = accumulator();
    const notice = reduceChatStreamEvent(acc, {
      type: "model-fallback",
      requestedModel: "missing-model",
      requestedProvider: "chosen-provider",
      model: "hermes-agent",
      reason: "incompatible",
    });
    expect(notice.patch.modelFallback).toMatchObject({
      requestedModel: "missing-model",
      model: "hermes-agent",
    });

    const delta = reduceChatStreamEvent(acc, {
      type: "delta",
      text: "Fallback answer",
    });
    expect(delta.patch).not.toHaveProperty("modelFallback");
    expect(acc.modelFallbackSeen).toBe(true);
  });
});
