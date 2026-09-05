import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  clearPendingDeletedThrough,
  clearPendingThrough,
  loadSyncAccountState,
  queueLocalConversationChanges,
  syncBackoffDelay,
} from "./cloud-sync-runtime";
import type { Conversation } from "./types";

beforeEach(() => {
  const values = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function conversation(id: string, content: string): Conversation {
  return {
    id,
    title: id,
    createdAt: 1,
    updatedAt: 10,
    messages: [{ id: `${id}-m`, role: "user", content, createdAt: 2 }],
  };
}

describe("incremental sync queue", () => {
  it("queues only the conversation whose object changed", () => {
    const first = conversation("first", "before");
    const untouched = conversation("untouched", "same");
    const changed: Conversation = {
      ...first,
      updatedAt: 20,
      messages: [{ ...first.messages[0]!, content: "after" }],
    };

    queueLocalConversationChanges({
      userId: "account-a",
      previous: [first, untouched],
      next: [changed, untouched],
      tombstones: {},
      now: 100,
    });

    const state = loadSyncAccountState("account-a");
    expect(Object.keys(state.pending)).toEqual(["first"]);
    expect(state.pending.first).toEqual({ version: 100, tombstone: false });
  });

  it("does not acknowledge a newer edit that happened during an upload", () => {
    const chat = conversation("chat", "one");
    queueLocalConversationChanges({
      userId: "account-b",
      previous: [],
      next: [chat],
      tombstones: {},
      now: 100,
    });
    const edited = {
      ...chat,
      messages: [{ ...chat.messages[0]!, content: "two" }],
    };
    queueLocalConversationChanges({
      userId: "account-b",
      previous: [chat],
      next: [edited],
      tombstones: {},
      now: 200,
    });

    clearPendingThrough("account-b", { chat: 100 }, 250);
    expect(loadSyncAccountState("account-b").pending.chat?.version).toBe(200);
  });

  it("clears an older pending edit when a newer remote deletion wins", () => {
    const chat = conversation("chat", "local edit");
    queueLocalConversationChanges({
      userId: "account-c",
      previous: [],
      next: [chat],
      tombstones: {},
      now: 100,
    });

    clearPendingDeletedThrough("account-c", "chat", 200);
    expect(loadSyncAccountState("account-c").pending.chat).toBeUndefined();
  });
});

describe("sync retry backoff", () => {
  it("grows exponentially and caps at one minute", () => {
    expect([0, 1, 2, 3, 4, 5, 6, 7].map(syncBackoffDelay)).toEqual([
      1_000,
      2_000,
      4_000,
      8_000,
      16_000,
      32_000,
      60_000,
      60_000,
    ]);
  });
});
