import { authHeaders } from "./auth/client";
import { conversationSchema } from "./conversation-contracts";
import type { Conversation } from "./types";
import { SyncKeyMismatchError } from "./sync-errors";
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

export { SyncKeyMismatchError } from "./sync-errors";

/**
 * Whether `master` can read what this account already holds.
 *
 * `empty` means there is nothing to read, and any key is therefore the right
 * one: this is the device that starts the set.
 */
/**
 * Whether this account already has an encrypted set.
 *
 * Asked before offering to make a key. Offering one regardless is how a
 * second device ended up starting a rival set beside the real one: the phrase
 * was generated, saved and switched on without anyone checking whether the
 * account was already syncing under a key this device simply did not have.
 */
export async function accountHasSyncSet(
  signal?: AbortSignal,
): Promise<boolean> {
  const response = syncPullResponseSchema.parse(
    await postSync({ action: "pull", cursor: "0", limit: 1 }, signal),
  );
  return response.records.length > 0;
}

/** The one record an account keeps purely so a key can be tested against it. */
export const VERIFIER_ID = "verifier:v1";
const VERIFIER_PLAINTEXT = { alice: "sync-verifier", version: 1 } as const;

/**
 * Whether `master` can read what this account already holds.
 *
 * Answered from the verifier where there is one — a single small record whose
 * plaintext is known, so a key can be tested without decrypting anybody's
 * conversations. Accounts written before the verifier existed fall back to
 * trying the conversations themselves.
 *
 * `empty` means there is nothing to read and any key is therefore the right
 * one: this is the device that starts the set.
 */
export async function verifySyncKey(options: {
  userId: string;
  master: Uint8Array;
  signal?: AbortSignal;
}): Promise<"matches" | "empty" | "mismatch"> {
  const key = await deriveContentKey(options.master, options.userId);
  let cursor = "0";
  let sawConversation = false;
  let readableConversation = false;
  for (;;) {
    const response = syncPullResponseSchema.parse(
      await postSync({ action: "pull", cursor, limit: 200 }, options.signal),
    );
    const verifier = response.records.find(
      (record) => record.id === VERIFIER_ID,
    );
    if (verifier) {
      try {
        await decryptPayload<unknown>(verifier.payload, key, VERIFIER_ID);
        return "matches";
      } catch {
        return "mismatch";
      }
    }
    for (const record of response.records) {
      if (!record.id.startsWith("conversation:")) continue;
      sawConversation = true;
      if (readableConversation) continue;
      try {
        await decryptPayload<unknown>(record.payload, key, record.id);
        readableConversation = true;
      } catch {
        // A damaged record does not prove the whole account uses another key.
      }
    }
    if (!response.hasMore) break;
    if (Number(response.cursor) <= Number(cursor))
      throw new Error("Sync verification cursor did not advance.");
    cursor = response.cursor;
  }
  // Legacy accounts may predate the verifier. Inspect every page before
  // treating an account as empty or accepting a legacy conversation's key.
  return readableConversation
    ? "matches"
    : sawConversation
      ? "mismatch"
      : "empty";
}

/**
 * Writes the verifier if the account has none.
 *
 * Called when a device starts a set, so every account written from here on
 * can be checked cheaply — and so a wrong key is refused by something that
 * costs one small record to read.
 */
export async function ensureSyncVerifier(options: {
  userId: string;
  master: Uint8Array;
  signal?: AbortSignal;
}): Promise<void> {
  if ((await verifySyncKey(options)) === "mismatch")
    throw new SyncKeyMismatchError();
  const key = await deriveContentKey(options.master, options.userId);
  const payload = await encryptPayload(VERIFIER_PLAINTEXT, key, VERIFIER_ID);
  await postSync(
    {
      action: "push",
      requestId: crypto.randomUUID(),
      records: [
        {
          id: VERIFIER_ID,
          kind: "verifier",
          clock: {
            wallTime: Date.now(),
            counter: 0,
            deviceId: deviceIdFor(options.userId),
          },
          tombstone: false,
          payload,
          byteSize: 0,
        },
      ],
    },
    options.signal,
  );
  // The server keeps the first verifier immutable. If another device created
  // the set while this one was confirming its phrase, only its key may win.
  if ((await verifySyncKey(options)) !== "matches")
    throw new SyncKeyMismatchError();
}

/** What a pull produced, and where it got to. */
export type SyncPull = {
  remote: RemoteConversation[];
  /**
   * How far this walk read. The caller writes it into the same persisted
   * state as the records, so both reach IndexedDB in one transaction or
   * neither does.
   */
  cursor: string;
};

export async function syncEncryptedConversations(options: {
  userId: string;
  master: Uint8Array;
  conversations: Conversation[];
  tombstones: ConversationTombstones;
  /**
   * Where to resume. Omitted only by callers that have never stored one, in
   * which case the position left behind by the old localStorage scheme is
   * read once so those devices do not re-walk their whole history.
   */
  cursor?: string;
  signal?: AbortSignal;
}): Promise<SyncPull> {
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

  const remote: RemoteConversation[] = [];
  let cursor = options.cursor ?? cursorFor(options.userId);
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
        // The runtime schema has already rejected malformed optional fields;
        // Zod's inferred optional shape is intentionally broader than the
        // exact persisted domain type.
        remote.push({
          id,
          tombstone: false,
          conversation: parsed.data as Conversation,
        });
      }
    }
    cursor = response.cursor;
    if (!response.hasMore) break;
  }

  // Only now does anything leave this device. Pushing first meant a key that
  // could not read the account still wrote to it: the failure surfaced on the
  // way back down, by which time this device's conversations were already in
  // there under a second key. Reading first, a wrong key throws while the
  // account is still untouched.
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

  // Handed back, never written here. Written per page, a failure on the
  // second page rejected the whole call — so the caller never saw the first
  // page's conversations — while the cursor had already moved past them. The
  // next run started after records it had never applied, and they stayed
  // missing until something changed them on the server.
  //
  // Nor is it written on its own afterwards: saved apart from the records, a
  // tab closing between the two saves the position and loses the contents.
  // The caller puts both into the persisted state together, and they reach
  // IndexedDB in one transaction or neither does.
  return { remote, cursor };
}

async function postSync(body: unknown, signal?: AbortSignal) {
  const response = await fetch("/api/sync", {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(body),
    ...(signal === undefined ? {} : { signal }),
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

/**
 * Where a device last read up to, for accounts synced before the position
 * moved into the store. Read-only: nothing writes here any more, and once the
 * caller has saved a position of its own this is never consulted again.
 */
function cursorFor(userId: string) {
  try {
    return localStorage.getItem(`alice:sync-cursor:${userId}`) ?? "0";
  } catch {
    return "0";
  }
}
