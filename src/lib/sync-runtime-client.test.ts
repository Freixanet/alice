import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateMasterSecret } from "./sync-crypto";
import { SyncKeyMismatchError } from "./sync-client";
import {
  CloudSyncQuotaError,
  pullConversationReplicas,
  pushConversationReplicas,
} from "./sync-runtime-client";
import type { ConversationReplicaV2 } from "./sync-replica";

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

function replica(): ConversationReplicaV2 {
  return {
    version: 2,
    updatedAt: 10,
    conversation: {
      id: "chat",
      title: "Chat",
      createdAt: 1,
      updatedAt: 10,
      messages: [{ id: "m", role: "user", content: "secret", createdAt: 2 }],
    },
    messageVersions: { m: 10 },
    messageTombstones: {},
  };
}

describe("incremental sync transport errors", () => {
  it("preserves the cloud quota error instead of flattening it", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        Response.json(
          { ok: false, error: { code: "cloud_quota_exceeded" } },
          { status: 409 },
        ),
      ),
    );

    await expect(
      pushConversationReplicas({
        userId: "account-a",
        master: generateMasterSecret(),
        replicas: [replica()],
        deletions: [],
      }),
    ).rejects.toBeInstanceOf(CloudSyncQuotaError);
  });

  it("surfaces ciphertext that the saved key cannot open as a key mismatch", async () => {
    let stored: Array<Record<string, unknown>> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        stored = body.records as Array<Record<string, unknown>>;
        return Response.json({ ok: true, replayed: false, accepted: stored.length });
      }),
    );
    await pushConversationReplicas({
      userId: "account-b",
      master: generateMasterSecret(),
      replicas: [replica()],
      deletions: [],
    });

    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        Response.json({
          ok: true,
          records: stored.map((record) => ({ ...record, revision: 1 })),
          cursor: "1",
          hasMore: false,
        }),
      ),
    );

    await expect(
      pullConversationReplicas({
        userId: "account-b",
        master: generateMasterSecret(),
        cursor: "0",
      }),
    ).rejects.toBeInstanceOf(SyncKeyMismatchError);
  });
});
