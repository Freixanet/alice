import { describe, expect, it } from "vitest";
import { mergeConversationReplicas, type ConversationReplicaV2 } from "./sync-replica";
import type { Conversation } from "./types";

function baseConversation(): Conversation {
  return {
    id: "shared-chat",
    title: "Shared",
    createdAt: 1,
    updatedAt: 10,
    messages: [
      { id: "m1", role: "user", content: "one", createdAt: 2 },
      { id: "m2", role: "assistant", content: "two", createdAt: 3 },
    ],
  };
}

function replica(
  conversation: Conversation,
  updatedAt: number,
  messageVersions: Record<string, number>,
  messageTombstones: Record<string, number> = {},
): ConversationReplicaV2 {
  return {
    version: 2,
    updatedAt,
    conversation,
    messageVersions,
    messageTombstones,
  };
}

describe("conversation replica merge", () => {
  it("keeps simultaneous edits to different messages from two devices", () => {
    const base = baseConversation();
    const deviceA = replica(
      {
        ...base,
        updatedAt: 20,
        messages: base.messages.map((message) =>
          message.id === "m1" ? { ...message, content: "edited on A" } : message,
        ),
      },
      20,
      { m1: 20, m2: 10 },
    );
    const deviceB = replica(
      {
        ...base,
        updatedAt: 21,
        messages: base.messages.map((message) =>
          message.id === "m2" ? { ...message, content: "edited on B" } : message,
        ),
      },
      21,
      { m1: 10, m2: 21 },
    );

    const merged = mergeConversationReplicas(deviceA, deviceB);
    expect(merged.conversation.messages).toEqual([
      { id: "m1", role: "user", content: "edited on A", createdAt: 2 },
      { id: "m2", role: "assistant", content: "edited on B", createdAt: 3 },
    ]);
    expect(merged.messageVersions).toEqual({ m1: 20, m2: 21 });
  });

  it("uses the per-message version when both devices edit the same message", () => {
    const base = baseConversation();
    const older = replica(
      {
        ...base,
        messages: [{ ...base.messages[0]!, content: "older" }, base.messages[1]!],
      },
      30,
      { m1: 30, m2: 10 },
    );
    const newer = replica(
      {
        ...base,
        messages: [{ ...base.messages[0]!, content: "newer" }, base.messages[1]!],
      },
      31,
      { m1: 31, m2: 10 },
    );

    expect(
      mergeConversationReplicas(older, newer).conversation.messages[0]!.content,
    ).toBe("newer");
  });

  it("does not resurrect a message removed on another device", () => {
    const base = baseConversation();
    const removed = replica(
      { ...base, updatedAt: 40, messages: [base.messages[0]!] },
      40,
      { m1: 10 },
      { m2: 40 },
    );
    const stale = replica(base, 10, { m1: 10, m2: 10 });

    const merged = mergeConversationReplicas(removed, stale);
    expect(merged.conversation.messages.map((message) => message.id)).toEqual([
      "m1",
    ]);
    expect(merged.messageTombstones.m2).toBe(40);
  });
});
