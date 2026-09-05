import { describe, expect, it } from "vitest";
import { seedBlankChat } from "./store";
import { uid } from "./utils";
import type { Conversation } from "./types";

/**
 * The merge itself lives inside a React effect, so this exercises the rule it
 * turns on: what a device is left holding when the only conversation it has is
 * one another device deleted.
 */
function merge(
  local: Conversation[],
  tombstones: Record<string, number>,
  remote: Array<{ id: string; updatedAt: number }>,
) {
  const byId = new Map(local.map((item) => [item.id, item]));
  const nextTombstones = { ...tombstones };
  for (const item of remote) {
    const current = byId.get(item.id);
    if (!current || current.updatedAt <= item.updatedAt) byId.delete(item.id);
    nextTombstones[item.id] = Math.max(
      nextTombstones[item.id] ?? 0,
      item.updatedAt,
    );
  }
  const next = [...byId.values()].sort((a, b) => b.updatedAt - a.updatedAt);
  const list = next.length
    ? next
    : [{ ...seedBlankChat(), id: uid(), title: "New chat" }];
  return { conversations: list, conversationTombstones: nextTombstones };
}

describe("applying a remote deletion", () => {
  const only: Conversation = {
    id: "only-one",
    title: "The only chat",
    createdAt: 1,
    updatedAt: 2,
    messages: [],
  };

  it("removes the last conversation and puts a fresh one in its place", () => {
    const result = merge([only], {}, [{ id: only.id, updatedAt: 5 }]);
    expect(result.conversations).toHaveLength(1);
    expect(result.conversations[0]!.id).not.toBe(only.id);
    expect(result.conversations[0]!.messages).toEqual([]);
    expect(result.conversationTombstones[only.id]).toBe(5);
  });

  it("keeps the tombstone, so the deletion is not undone on the next run", () => {
    const first = merge([only], {}, [{ id: only.id, updatedAt: 5 }]);
    const second = merge(
      first.conversations,
      first.conversationTombstones,
      [{ id: only.id, updatedAt: 5 }],
    );
    expect(second.conversationTombstones[only.id]).toBe(5);
    expect(
      second.conversations.some((item) => item.id === only.id),
    ).toBe(false);
  });

  it("leaves other conversations alone", () => {
    const other: Conversation = { ...only, id: "other", updatedAt: 9 };
    const result = merge([only, other], {}, [{ id: only.id, updatedAt: 5 }]);
    expect(result.conversations.map((c) => c.id)).toEqual(["other"]);
  });
});
