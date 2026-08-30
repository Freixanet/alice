import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateMasterSecret } from "./sync-crypto";
import { syncEncryptedConversations } from "./sync-client";
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

describe("encrypted sync client", () => {
  it("uploads ciphertext and validates/decrypts resumed pull pages", async () => {
    const conversation: Conversation = {
      id: "chat-one",
      title: "Private title",
      createdAt: 1,
      updatedAt: 2,
      messages: [
        {
          id: "message-one",
          role: "user",
          content: "private content",
          createdAt: 2,
        },
      ],
    };
    let uploaded: Record<string, unknown> | null = null;
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        if (body.action === "push") {
          uploaded = body;
          return Response.json({ ok: true, replayed: false, accepted: 1 });
        }
        const record = (uploaded?.records as Array<Record<string, unknown>>)[0];
        return Response.json({
          ok: true,
          records: [{ ...record, revision: 1 }],
          cursor: "1",
          hasMore: false,
        });
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const result = await syncEncryptedConversations({
      userId: "account-a",
      master: generateMasterSecret(),
      conversations: [conversation],
      tombstones: {},
    });

    expect(JSON.stringify(uploaded)).not.toContain("private content");
    expect(result).toEqual([
      { id: conversation.id, tombstone: false, conversation },
    ]);
    expect(localStorage.getItem("alice:sync-cursor:account-a")).toBe("1");
  });
});
