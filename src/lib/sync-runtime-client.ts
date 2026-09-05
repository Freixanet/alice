import { authHeaders } from "./auth/client";
import { conversationSchema } from "./conversation-contracts";
import {
  syncPullResponseSchema,
  syncPushResponseSchema,
  type EncryptedSyncRecord,
} from "./sync-contracts";
import {
  decryptPayload,
  deriveContentKey,
  encryptPayload,
} from "./sync-crypto";
import { SyncKeyMismatchError } from "./sync-errors";
import {
  legacyConversationReplica,
  type ConversationReplicaV2,
} from "./sync-replica";
import type { Conversation } from "./types";

const REPLICA_PREFIX = "conversation:v2:";
const DELETE_PREFIX = "conversation-delete:v2:";
const volatileDeviceIds = new Map<string, string>();

export type RemoteReplicaRecord =
  | { type: "replica"; id: string; replica: ConversationReplicaV2 }
  | { type: "tombstone"; id: string; updatedAt: number };

export class CloudSyncNetworkError extends Error {
  constructor() {
    super("cloud_sync_network_error");
    this.name = "CloudSyncNetworkError";
  }
}

export class CloudSyncQuotaError extends Error {
  constructor() {
    super("cloud_quota_exceeded");
    this.name = "CloudSyncQuotaError";
  }
}

export class CloudSyncHttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.name = "CloudSyncHttpError";
    this.status = status;
    this.code = code;
  }
}

function finiteRecord(value: unknown): Record<string, number> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const out: Record<string, number> = {};
  for (const [key, candidate] of Object.entries(value)) {
    if (
      typeof candidate !== "number" ||
      !Number.isSafeInteger(candidate) ||
      candidate < 0
    ) {
      return null;
    }
    out[key] = candidate;
  }
  return out;
}

function parseReplica(value: unknown): ConversationReplicaV2 | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  if (
    candidate.version !== 2 ||
    typeof candidate.updatedAt !== "number" ||
    !Number.isSafeInteger(candidate.updatedAt) ||
    candidate.updatedAt < 0
  ) {
    return null;
  }
  const conversation = conversationSchema.safeParse(candidate.conversation);
  const messageVersions = finiteRecord(candidate.messageVersions);
  const messageTombstones = finiteRecord(candidate.messageTombstones);
  if (!conversation.success || !messageVersions || !messageTombstones)
    return null;
  return {
    version: 2,
    updatedAt: candidate.updatedAt,
    conversation: conversation.data as Conversation,
    messageVersions,
    messageTombstones,
  };
}

function parseDeletion(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  if (
    candidate.version !== 2 ||
    typeof candidate.id !== "string" ||
    !candidate.id ||
    candidate.id.length > 160 ||
    typeof candidate.updatedAt !== "number" ||
    !Number.isSafeInteger(candidate.updatedAt) ||
    candidate.updatedAt < 0
  ) {
    return null;
  }
  return { id: candidate.id, updatedAt: candidate.updatedAt };
}

async function postSync(body: unknown, signal?: AbortSignal) {
  let response: Response;
  try {
    response = await fetch("/api/sync", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(body),
      ...(signal === undefined ? {} : { signal }),
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError")
      throw error;
    throw new CloudSyncNetworkError();
  }

  let value: unknown = null;
  try {
    value = (await response.json()) as unknown;
  } catch {
    if (!response.ok)
      throw new CloudSyncHttpError(response.status, "cloud_sync_failed");
  }

  if (!response.ok) {
    const code =
      value && typeof value === "object" && !Array.isArray(value)
        ? ((value as { error?: { code?: unknown } }).error?.code ??
          "cloud_sync_failed")
        : "cloud_sync_failed";
    if (code === "cloud_quota_exceeded") throw new CloudSyncQuotaError();
    throw new CloudSyncHttpError(
      response.status,
      typeof code === "string" ? code : "cloud_sync_failed",
    );
  }
  return value;
}

function deviceIdFor(userId: string) {
  const key = `alice:sync-device:${userId}`;
  try {
    const current = localStorage.getItem(key);
    if (current) {
      volatileDeviceIds.set(userId, current);
      return current;
    }
  } catch {
    // Use the stable tab-local fallback below.
  }

  const existing = volatileDeviceIds.get(userId);
  if (existing) return existing;
  const created = crypto.randomUUID();
  volatileDeviceIds.set(userId, created);
  try {
    localStorage.setItem(key, created);
  } catch {
    // The map keeps the id stable for this tab when storage is unavailable.
  }
  return created;
}

function toBase64Url(bytes: Uint8Array) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}

async function recordDigest(
  conversationId: string,
  deviceId: string,
  purpose: "replica" | "delete",
) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(
      `${purpose}\u0000${conversationId}\u0000${deviceId}`,
    ),
  );
  return toBase64Url(new Uint8Array(digest));
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

export async function pullConversationReplicas(options: {
  userId: string;
  master: Uint8Array;
  cursor?: string;
  signal?: AbortSignal;
}) {
  options.signal?.throwIfAborted();
  const key = await deriveContentKey(options.master, options.userId);
  const remote: RemoteReplicaRecord[] = [];
  let cursor = options.cursor ?? "0";

  for (let page = 0; page < 100; page += 1) {
    options.signal?.throwIfAborted();
    const response = syncPullResponseSchema.parse(
      await postSync({ action: "pull", cursor, limit: 200 }, options.signal),
    );

    for (const record of response.records) {
      options.signal?.throwIfAborted();
      if (record.kind !== "conversation") continue;
      try {
        if (record.id.startsWith(REPLICA_PREFIX)) {
          const value = await decryptPayload<unknown>(
            record.payload,
            key,
            record.id,
          );
          const replica = parseReplica(value);
          if (replica) {
            remote.push({
              type: "replica",
              id: replica.conversation.id,
              replica,
            });
          }
          continue;
        }

        if (record.id.startsWith(DELETE_PREFIX)) {
          const value = await decryptPayload<unknown>(
            record.payload,
            key,
            record.id,
          );
          const deletion = parseDeletion(value);
          if (deletion) remote.push({ type: "tombstone", ...deletion });
          continue;
        }

        // Legacy v1 whole-conversation rows remain readable during migration.
        if (!record.id.startsWith("conversation:")) continue;
        const id = record.id.slice("conversation:".length);
        if (record.tombstone) {
          remote.push({
            type: "tombstone",
            id,
            updatedAt: record.clock.wallTime,
          });
          continue;
        }
        const value = await decryptPayload<unknown>(
          record.payload,
          key,
          record.id,
        );
        const parsed = conversationSchema.safeParse(value);
        if (parsed.success) {
          const conversation = parsed.data as Conversation;
          remote.push({
            type: "replica",
            id: conversation.id,
            replica: legacyConversationReplica(conversation),
          });
        }
      } catch (error) {
        if (error instanceof DOMException && error.name === "AbortError")
          throw error;
        // A saved key that can no longer open account ciphertext is not a
        // successful sync. Surface it instead of silently skipping records.
        throw new SyncKeyMismatchError();
      }
    }

    cursor = response.cursor;
    if (!response.hasMore) break;
  }

  return { remote, cursor };
}

export async function pushConversationReplicas(options: {
  userId: string;
  master: Uint8Array;
  replicas: ConversationReplicaV2[];
  deletions: Array<{ id: string; updatedAt: number }>;
  signal?: AbortSignal;
}) {
  options.signal?.throwIfAborted();
  if (!options.replicas.length && !options.deletions.length)
    return { accepted: 0 };

  const key = await deriveContentKey(options.master, options.userId);
  const deviceId = deviceIdFor(options.userId);
  const records: EncryptedSyncRecord[] = [];

  for (const replica of options.replicas) {
    options.signal?.throwIfAborted();
    const digest = await recordDigest(
      replica.conversation.id,
      deviceId,
      "replica",
    );
    const recordId = `${REPLICA_PREFIX}${digest}`;
    const payload = await encryptPayload(replica, key, recordId);
    records.push({
      id: recordId,
      kind: "conversation",
      clock: { wallTime: replica.updatedAt, counter: 0, deviceId },
      tombstone: false,
      payload,
      byteSize: new TextEncoder().encode(JSON.stringify(replica)).length,
    });
  }

  for (const deletion of options.deletions) {
    options.signal?.throwIfAborted();
    const digest = await recordDigest(deletion.id, deviceId, "delete");
    const recordId = `${DELETE_PREFIX}${digest}`;
    const value = { version: 2 as const, ...deletion };
    const payload = await encryptPayload(value, key, recordId);
    records.push({
      id: recordId,
      kind: "conversation",
      clock: { wallTime: deletion.updatedAt, counter: 0, deviceId },
      tombstone: true,
      payload,
      byteSize: new TextEncoder().encode(JSON.stringify(value)).length,
    });
  }

  let accepted = 0;
  for (const batch of batches(records)) {
    options.signal?.throwIfAborted();
    const response = syncPushResponseSchema.parse(
      await postSync(
        {
          action: "push",
          requestId: crypto.randomUUID(),
          records: batch,
        },
        options.signal,
      ),
    );
    accepted += response.accepted;
  }
  return { accepted };
}
