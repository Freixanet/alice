import { authHeaders } from "./auth/client";
import { conversationSchema } from "./conversation-contracts";
import type { Conversation } from "./types";
import {
  deriveContentKey,
  decryptPayload,
  encryptPayload,
} from "./sync-crypto";
import {
  syncPullResponseSchema,
  syncPushResponseSchema,
  type EncryptedSyncRecord,
} from "./sync-contracts";

export type ConversationTombstones = Record<string, number>;
export type RemoteConversation =
  | { id: string; tombstone: true; updatedAt: number }
  | { id: string; tombstone: false; conversation: Conversation };

export async function syncEncryptedConversations(options: {
  userId: string;
  master: Uint8Array;
  conversations: Conversation[];
  tombstones: ConversationTombstones;
  signal?: AbortSignal;
}): Promise<RemoteConversation[]> {
  options.signal?.throwIfAborted();
  const key = await deriveContentKey(options.master, options.userId);
  options.signal?.throwIfAborted();
  const deviceId = deviceIdFor(options.userId);
  const records: EncryptedSyncRecord[] = [];
  for (const conversation of options.conversations) {
    options.signal?.throwIfAborted();
    const payload = await encryptPayload(
      conversation,
      key,
      `conversation:${conversation.id}`,
    );
    records.push({
      id: `conversation:${conversation.id}`,
      kind: "conversation",
      clock: {
        wallTime: conversation.updatedAt,
        counter: 0,
        deviceId,
      },
      tombstone: false,
      payload,
      byteSize: new TextEncoder().encode(JSON.stringify(conversation)).length,
    });
  }
  for (const [id, updatedAt] of Object.entries(options.tombstones)) {
    options.signal?.throwIfAborted();
    const payload = await encryptPayload(
      { id, updatedAt },
      key,
      `conversation:${id}`,
    );
    records.push({
      id: `conversation:${id}`,
      kind: "conversation",
      clock: { wallTime: updatedAt, counter: 0, deviceId },
      tombstone: true,
      payload,
      byteSize: 0,
    });
  }

  for (const batch of batches(records)) {
    options.signal?.throwIfAborted();
    const response = await postSync(
      {
        action: "push",
        requestId: crypto.randomUUID(),
        records: batch,
      },
      options.signal,
    );
    syncPushResponseSchema.parse(response);
  }

  const remote: RemoteConversation[] = [];
  let cursor = cursorFor(options.userId);
  for (let page = 0; page < 100; page += 1) {
    options.signal?.throwIfAborted();
    const response = syncPullResponseSchema.parse(
      await postSync({ action: "pull", cursor, limit: 200 }, options.signal),
    );
    for (const record of response.records) {
      options.signal?.throwIfAborted();
      if (!record.id.startsWith("conversation:")) continue;
      const id = record.id.slice("conversation:".length);
      if (record.tombstone) {
        remote.push({ id, tombstone: true, updatedAt: record.clock.wallTime });
        continue;
      }
      const value = await decryptPayload<unknown>(
        record.payload,
        key,
        record.id,
      );
      const parsed = conversationSchema.safeParse(value);
      if (parsed.success) {
        remote.push({ id, tombstone: false, conversation: parsed.data });
      }
    }
    cursor = response.cursor;
    setCursor(options.userId, cursor);
    if (!response.hasMore) break;
  }
  return remote;
}

async function postSync(body: unknown, signal?: AbortSignal) {
  const response = await fetch("/api/sync", {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(body),
    signal,
  });
  const value = (await response.json()) as unknown;
  if (!response.ok) throw new Error("cloud_sync_failed");
  return value;
}

function batches(records: EncryptedSyncRecord[]) {
  const out: EncryptedSyncRecord[][] = [];
  let current: EncryptedSyncRecord[] = [];
  let bytes = 0;
  for (const record of records) {
    const size = record.payload.ciphertext.length + 1_024;
    if (
      current.length &&
      (current.length >= 100 || bytes + size > 12_000_000)
    ) {
      out.push(current);
      current = [];
      bytes = 0;
    }
    current.push(record);
    bytes += size;
  }
  if (current.length) out.push(current);
  return out;
}

function deviceIdFor(userId: string) {
  const key = `alice:sync-device:${userId}`;
  const current = localStorage.getItem(key);
  if (current) return current;
  const created = crypto.randomUUID();
  localStorage.setItem(key, created);
  return created;
}

function cursorFor(userId: string) {
  return localStorage.getItem(`alice:sync-cursor:${userId}`) ?? "0";
}

function setCursor(userId: string, cursor: string) {
  localStorage.setItem(`alice:sync-cursor:${userId}`, cursor);
}
