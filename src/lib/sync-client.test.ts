import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateMasterSecret } from "./sync-crypto";
import {
  VERIFIER_ID,
  accountHasSyncSet,
  ensureSyncVerifier,
  syncEncryptedConversations,
  verifySyncKey,
} from "./sync-client";
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

  it("uploads ciphertext, then reads it back on a later run", async () => {
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
        const records = uploaded
          ? (uploaded.records as Array<Record<string, unknown>>).map((r) => ({
              ...r,
              revision: 1,
            }))
          : [];
        return Response.json({
          ok: true,
          records,
          cursor: "1",
          hasMore: false,
        });
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const master = generateMasterSecret();
    // First run: an empty account, so the walk reads nothing and this device's
    // conversation goes up.
    const first = await syncEncryptedConversations({
      userId: "account-a",
      master,
      conversations: [conversation],
      tombstones: {},
    });
    expect(first.remote).toEqual([]);
    expect(JSON.stringify(uploaded)).not.toContain("private content");

    // Second run: what was written comes back, and decrypts.
    const second = await syncEncryptedConversations({
      userId: "account-a",
      master,
      conversations: [],
      tombstones: {},
    });
    expect(second.remote).toEqual([
      { id: conversation.id, tombstone: false, conversation },
    ]);
    expect(second.cursor).toBe("1");
    expect(localStorage.getItem("alice:sync-cursor:account-a")).toBeNull();
  });

  it("refuses a key that cannot read the account, before writing", async () => {
    // A well-formed phrase belonging to a different key. The account already
    // holds records, so the walk fails on the first one it tries to open —
    // and it must fail with nothing pushed.
    const owner = generateMasterSecret();
    let stored: Array<Record<string, unknown>> = [];
    let pushes = 0;
    const seed = vi.fn(async (_i: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      if (body.action === "push") {
        stored = (body.records as Array<Record<string, unknown>>).map((r) => ({
          ...r,
          revision: 1,
        }));
        return Response.json({ ok: true, replayed: false, accepted: 1 });
      }
      return Response.json({ ok: true, records: [], cursor: "1", hasMore: false });
    });
    vi.stubGlobal("fetch", seed);
    await syncEncryptedConversations({
      userId: "account-d",
      master: owner,
      conversations: [
        { id: "c", title: "t", createdAt: 1, updatedAt: 2, messages: [] },
      ],
      tombstones: {},
    });

    const intruder = vi.fn(async (_i: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      if (body.action === "push") {
        pushes += 1;
        return Response.json({ ok: true, replayed: false, accepted: 1 });
      }
      return Response.json({
        ok: true,
        records: stored,
        cursor: "2",
        hasMore: false,
      });
    });
    vi.stubGlobal("fetch", intruder);

    await expect(
      syncEncryptedConversations({
        userId: "account-d",
        master: generateMasterSecret(),
        conversations: [
          { id: "mine", title: "m", createdAt: 1, updatedAt: 9, messages: [] },
        ],
        tombstones: {},
        cursor: "0",
      }),
    ).rejects.toThrow();
    expect(pushes).toBe(0);
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

  it("resumes from the position it is given", async () => {
    // The caller keeps the position, so the client asks for pages after
    // whatever it is handed rather than looking it up for itself.
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        if (body.action === "push") {
          return Response.json({ ok: true, replayed: false, accepted: 0 });
        }
        expect(body.cursor).toBe("42");
        return Response.json({
          ok: true,
          records: [],
          cursor: "43",
          hasMore: false,
        });
      },
    );
    vi.stubGlobal("fetch", fetchMock);

    const result = await syncEncryptedConversations({
      userId: "account-c",
      master: generateMasterSecret(),
      conversations: [],
      tombstones: {},
      cursor: "42",
    });
    expect(result.cursor).toBe("43");
  });
});

describe("key verification", () => {
  it("answers from the verifier without touching conversations", async () => {
    const master = generateMasterSecret();
    let written: Array<Record<string, unknown>> = [];
    const seed = vi.fn(async (_i: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      if (body.action === "push") {
        written = (body.records as Array<Record<string, unknown>>).map((r) => ({
          ...r,
          revision: 1,
        }));
        return Response.json({ ok: true, replayed: false, accepted: 1 });
      }
      return Response.json({ ok: true, records: [], cursor: "1", hasMore: false });
    });
    vi.stubGlobal("fetch", seed);
    await ensureSyncVerifier({ userId: "account-e", master });
    expect(written[0]?.id).toBe(VERIFIER_ID);
    expect(written[0]?.kind).toBe("verifier");

    const reader = vi.fn(async () =>
      Response.json({ ok: true, records: written, cursor: "2", hasMore: false }),
    );
    vi.stubGlobal("fetch", reader);
    await expect(
      verifySyncKey({ userId: "account-e", master }),
    ).resolves.toBe("matches");
    await expect(
      verifySyncKey({ userId: "account-e", master: generateMasterSecret() }),
    ).resolves.toBe("mismatch");
  });

  it("calls an untouched account empty, so the first device may start it", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        Response.json({ ok: true, records: [], cursor: "0", hasMore: false }),
      ),
    );
    await expect(
      verifySyncKey({ userId: "account-f", master: generateMasterSecret() }),
    ).resolves.toBe("empty");
    await expect(accountHasSyncSet()).resolves.toBe(false);
  });
});
