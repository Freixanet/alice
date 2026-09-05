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
  it("stops before encryption or network work when its owner is gone", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const controller = new AbortController();
    controller.abort();
    await expect(
      syncEncryptedConversations({
        userId: "account-a",
        master: generateMasterSecret(),
        conversations: [],
        tombstones: {},
        signal: controller.signal,
      }),
    ).rejects.toMatchObject({ name: "AbortError" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

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
    expect(result.remote).toEqual([
      { id: conversation.id, tombstone: false, conversation },
    ]);
    // Not yet: the walk finished but nobody has stored anything.
    expect(localStorage.getItem("alice:sync-cursor:account-a")).toBeNull();
    result.commitCursor();
    expect(localStorage.getItem("alice:sync-cursor:account-a")).toBe("1");
  });

  it("leaves the cursor alone when a later page fails", async () => {
    // The first page arrives and the second does not. Nothing reaches the
    // caller, so the position must not move: a device that advanced here
    // would never be sent the first page again, and would go on missing
    // conversations that are still in the cloud.
    localStorage.setItem("alice:sync-cursor:account-b", "7");
    let pulls = 0;
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        if (body.action === "push") {
          return Response.json({ ok: true, replayed: false, accepted: 0 });
        }
        pulls += 1;
        if (pulls === 1) {
          return Response.json({
            ok: true,
            records: [],
            cursor: "9",
            hasMore: true,
          });
        }
        throw new Error("network went away");
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      syncEncryptedConversations({
        userId: "account-b",
        master: generateMasterSecret(),
        conversations: [],
        tombstones: {},
      }),
    ).rejects.toThrow("network went away");

    expect(localStorage.getItem("alice:sync-cursor:account-b")).toBe("7");
  });

  it("keeps each account's position apart", async () => {
    localStorage.setItem("alice:sync-cursor:account-a", "4");
    localStorage.setItem("alice:sync-cursor:account-b", "11");
    expect(localStorage.getItem("alice:sync-cursor:account-a")).toBe("4");
    expect(localStorage.getItem("alice:sync-cursor:account-b")).toBe("11");
  });
});
