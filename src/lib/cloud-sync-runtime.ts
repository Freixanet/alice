import { create } from "zustand";
import type { Conversation } from "./types";
import type { ConversationReplicaV2 } from "./sync-replica";

export type CloudSyncStatus =
  | "idle"
  | "syncing"
  | "synced"
  | "pending"
  | "offline"
  | "key-mismatch"
  | "quota-exceeded"
  | "error";

export type SyncPendingEntry = {
  version: number;
  tombstone: boolean;
};

type PersistedAccountSyncState = {
  version: 1;
  initialized: boolean;
  pending: Record<string, SyncPendingEntry>;
  conversationVersions: Record<string, number>;
  lastSyncedAt: number | null;
};

type PersistedMessageSyncState = {
  version: 1;
  messageVersions: Record<string, number>;
  messageTombstones: Record<string, number>;
};

type RuntimeView = {
  userId: string | null;
  status: CloudSyncStatus;
  lastSyncedAt: number | null;
  pendingCount: number;
};

type RuntimeStore = RuntimeView & {
  setView: (view: Partial<RuntimeView>) => void;
};

const EMPTY_ACCOUNT: PersistedAccountSyncState = {
  version: 1,
  initialized: false,
  pending: {},
  conversationVersions: {},
  lastSyncedAt: null,
};

const memoryStorage = new Map<string, string>();

export const useCloudSyncRuntime = create<RuntimeStore>((set) => ({
  userId: null,
  status: "idle",
  lastSyncedAt: null,
  pendingCount: 0,
  setView: (view) => set(view),
}));

function accountKey(userId: string) {
  return `alice:sync-runtime:v1:${userId}`;
}

function messageKey(userId: string, conversationId: string) {
  return `alice:sync-messages:v1:${userId}:${encodeURIComponent(conversationId)}`;
}

function storageGet(key: string) {
  try {
    if (typeof localStorage !== "undefined") {
      const stored = localStorage.getItem(key);
      if (stored !== null) {
        memoryStorage.set(key, stored);
        return stored;
      }
    }
  } catch {
    // Fall through to the tab-local copy below.
  }
  return memoryStorage.get(key) ?? null;
}

function storageSet(key: string, value: string) {
  memoryStorage.set(key, value);
  try {
    if (typeof localStorage !== "undefined") localStorage.setItem(key, value);
  } catch {
    // Storage-denied/private contexts still retain a correct queue for the
    // lifetime of this tab instead of generating and forgetting state.
  }
}

function finiteRecord(value: unknown): Record<string, number> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const out: Record<string, number> = {};
  for (const [key, candidate] of Object.entries(value)) {
    if (
      typeof candidate === "number" &&
      Number.isSafeInteger(candidate) &&
      candidate >= 0
    ) {
      out[key] = candidate;
    }
  }
  return out;
}

function parsePending(value: unknown): Record<string, SyncPendingEntry> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const out: Record<string, SyncPendingEntry> = {};
  for (const [id, candidate] of Object.entries(value)) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate))
      continue;
    const item = candidate as Record<string, unknown>;
    if (
      typeof item.version === "number" &&
      Number.isSafeInteger(item.version) &&
      item.version >= 0 &&
      typeof item.tombstone === "boolean"
    ) {
      out[id] = { version: item.version, tombstone: item.tombstone };
    }
  }
  return out;
}

export function loadSyncAccountState(
  userId: string,
): PersistedAccountSyncState {
  const raw = storageGet(accountKey(userId));
  if (!raw) return { ...EMPTY_ACCOUNT, pending: {}, conversationVersions: {} };
  try {
    const value = JSON.parse(raw) as Record<string, unknown>;
    return {
      version: 1,
      initialized: value.initialized === true,
      pending: parsePending(value.pending),
      conversationVersions: finiteRecord(value.conversationVersions),
      lastSyncedAt:
        typeof value.lastSyncedAt === "number" &&
        Number.isSafeInteger(value.lastSyncedAt) &&
        value.lastSyncedAt >= 0
          ? value.lastSyncedAt
          : null,
    };
  } catch {
    return { ...EMPTY_ACCOUNT, pending: {}, conversationVersions: {} };
  }
}

function saveSyncAccountState(
  userId: string,
  state: PersistedAccountSyncState,
) {
  storageSet(accountKey(userId), JSON.stringify(state));
  const runtime = useCloudSyncRuntime.getState();
  if (runtime.userId === userId) {
    runtime.setView({
      lastSyncedAt: state.lastSyncedAt,
      pendingCount: Object.keys(state.pending).length,
    });
  }
}

export function loadMessageSyncState(
  userId: string,
  conversationId: string,
): PersistedMessageSyncState {
  const raw = storageGet(messageKey(userId, conversationId));
  if (!raw) return { version: 1, messageVersions: {}, messageTombstones: {} };
  try {
    const value = JSON.parse(raw) as Record<string, unknown>;
    return {
      version: 1,
      messageVersions: finiteRecord(value.messageVersions),
      messageTombstones: finiteRecord(value.messageTombstones),
    };
  } catch {
    return { version: 1, messageVersions: {}, messageTombstones: {} };
  }
}

function saveMessageSyncState(
  userId: string,
  conversationId: string,
  state: PersistedMessageSyncState,
) {
  storageSet(messageKey(userId, conversationId), JSON.stringify(state));
}

function nextVersion(previous: number | undefined, now: number) {
  return Math.max(now, (previous ?? 0) + 1);
}

function markConversationChanged(
  userId: string,
  account: PersistedAccountSyncState,
  previous: Conversation | undefined,
  next: Conversation,
  now: number,
) {
  const version = nextVersion(account.conversationVersions[next.id], now);
  account.conversationVersions[next.id] = version;
  account.pending[next.id] = { version, tombstone: false };

  const messageState = loadMessageSyncState(userId, next.id);
  const previousById = new Map(
    previous?.messages.map((message) => [message.id, message]),
  );
  const nextIds = new Set<string>();
  for (const message of next.messages) {
    nextIds.add(message.id);
    const prior = previousById.get(message.id);
    if (!prior || prior !== message) {
      messageState.messageVersions[message.id] = nextVersion(
        messageState.messageVersions[message.id],
        now,
      );
      delete messageState.messageTombstones[message.id];
    } else if (messageState.messageVersions[message.id] === undefined) {
      messageState.messageVersions[message.id] = message.createdAt;
    }
  }
  if (previous) {
    for (const message of previous.messages) {
      if (nextIds.has(message.id)) continue;
      messageState.messageTombstones[message.id] = nextVersion(
        messageState.messageTombstones[message.id],
        now,
      );
      delete messageState.messageVersions[message.id];
    }
  }
  saveMessageSyncState(userId, next.id, messageState);
}

/**
 * Capture a local store mutation without serialising or encrypting the rest of
 * the history. Zustand preserves object identity for untouched conversations,
 * so one changed chat normally means one queue entry and only that chat's
 * message clocks are inspected.
 */
export function queueLocalConversationChanges(options: {
  userId: string;
  previous: Conversation[];
  next: Conversation[];
  tombstones: Record<string, number>;
  now?: number;
}) {
  const now = options.now ?? Date.now();
  const account = loadSyncAccountState(options.userId);
  const previousById = new Map(options.previous.map((item) => [item.id, item]));
  const nextIds = new Set(options.next.map((item) => item.id));

  for (const conversation of options.next) {
    const previous = previousById.get(conversation.id);
    if (previous === conversation) continue;
    markConversationChanged(
      options.userId,
      account,
      previous,
      conversation,
      now,
    );
  }

  for (const previous of options.previous) {
    if (nextIds.has(previous.id)) continue;
    const deletedAt = options.tombstones[previous.id] ?? now;
    const version = nextVersion(
      account.conversationVersions[previous.id],
      Math.max(now, deletedAt),
    );
    account.conversationVersions[previous.id] = version;
    account.pending[previous.id] = { version, tombstone: true };
  }

  saveSyncAccountState(options.userId, account);
}

/** Seed the v2 queue once after upgrading or enabling sync on this device. */
export function bootstrapSyncQueue(options: {
  userId: string;
  conversations: Conversation[];
  tombstones: Record<string, number>;
}) {
  const account = loadSyncAccountState(options.userId);
  if (account.initialized) return account;

  for (const conversation of options.conversations) {
    const version = Math.max(conversation.updatedAt, conversation.createdAt, 1);
    account.conversationVersions[conversation.id] = Math.max(
      account.conversationVersions[conversation.id] ?? 0,
      version,
    );
    account.pending[conversation.id] = {
      version: account.conversationVersions[conversation.id]!,
      tombstone: false,
    };
    const messages = loadMessageSyncState(options.userId, conversation.id);
    for (const message of conversation.messages) {
      if (messages.messageVersions[message.id] === undefined) {
        // A pre-v2 snapshot cannot tell when an old message was last patched.
        // The conversation timestamp is the conservative migration clock.
        messages.messageVersions[message.id] = Math.max(
          message.createdAt,
          conversation.updatedAt,
        );
      }
    }
    saveMessageSyncState(options.userId, conversation.id, messages);
  }

  for (const [id, deletedAt] of Object.entries(options.tombstones)) {
    const version = Math.max(
      deletedAt,
      account.conversationVersions[id] ?? 0,
      1,
    );
    account.conversationVersions[id] = version;
    account.pending[id] = { version, tombstone: true };
  }

  account.initialized = true;
  saveSyncAccountState(options.userId, account);
  return account;
}

export function buildLocalReplica(
  userId: string,
  conversation: Conversation,
): ConversationReplicaV2 {
  const account = loadSyncAccountState(userId);
  const messageState = loadMessageSyncState(userId, conversation.id);
  const messageVersions = { ...messageState.messageVersions };
  for (const message of conversation.messages) {
    if (messageVersions[message.id] === undefined) {
      messageVersions[message.id] = message.createdAt;
    }
  }
  return {
    version: 2,
    updatedAt:
      account.conversationVersions[conversation.id] ?? conversation.updatedAt,
    conversation,
    messageVersions,
    messageTombstones: { ...messageState.messageTombstones },
  };
}

export function applyMergedReplicaState(
  userId: string,
  replica: ConversationReplicaV2,
) {
  const account = loadSyncAccountState(userId);
  account.conversationVersions[replica.conversation.id] = Math.max(
    account.conversationVersions[replica.conversation.id] ?? 0,
    replica.updatedAt,
  );
  saveSyncAccountState(userId, account);
  saveMessageSyncState(userId, replica.conversation.id, {
    version: 1,
    messageVersions: { ...replica.messageVersions },
    messageTombstones: { ...replica.messageTombstones },
  });
}

export function clearPendingThrough(
  userId: string,
  sent: Record<string, number>,
  lastSyncedAt: number,
) {
  const account = loadSyncAccountState(userId);
  for (const [id, version] of Object.entries(sent)) {
    const pending = account.pending[id];
    if (pending && pending.version <= version) delete account.pending[id];
  }
  account.lastSyncedAt = lastSyncedAt;
  saveSyncAccountState(userId, account);
}

export function clearPendingDeletedThrough(
  userId: string,
  conversationId: string,
  deletedAt: number,
) {
  const account = loadSyncAccountState(userId);
  const pending = account.pending[conversationId];
  if (pending && pending.version <= deletedAt) {
    delete account.pending[conversationId];
    saveSyncAccountState(userId, account);
  }
}

export function setCloudSyncRuntimeStatus(
  userId: string,
  status: CloudSyncStatus,
) {
  const account = loadSyncAccountState(userId);
  useCloudSyncRuntime.getState().setView({
    userId,
    status,
    lastSyncedAt: account.lastSyncedAt,
    pendingCount: Object.keys(account.pending).length,
  });
}

export function resetCloudSyncRuntimeStatus() {
  useCloudSyncRuntime.getState().setView({
    userId: null,
    status: "idle",
    lastSyncedAt: null,
    pendingCount: 0,
  });
}

export function syncBackoffDelay(attempt: number) {
  const exponent = Math.max(0, Math.min(6, Math.floor(attempt)));
  return Math.min(60_000, 1_000 * 2 ** exponent);
}
