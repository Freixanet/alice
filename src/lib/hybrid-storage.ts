import type { StateStorage } from "zustand/middleware";

const DATABASE = "alice-private-v1";
const STORE = "account-state";
const DURABLE_FIELDS = new Set([
  "conversations",
  "conversationTombstones",
  "activeId",
  "memories",
  "jobs",
  "hooks",
  "approvals",
]);

type Envelope = { state: Record<string, unknown>; version?: number };

export function createHybridStorage(options: {
  userId: () => string | null;
  isLegacyOwner: () => boolean;
  local?: Storage;
  indexedDb?: IDBFactory;
}): StateStorage {
  const local =
    options.local ??
    (typeof globalThis.localStorage === "undefined"
      ? null
      : globalThis.localStorage);
  const indexedDb =
    options.indexedDb ??
    (typeof globalThis.indexedDB === "undefined" ? null : globalThis.indexedDB);
  if (!local || !indexedDb) {
    return {
      getItem: () => null,
      setItem: () => undefined,
      removeItem: () => undefined,
    };
  }

  return {
    async getItem(name) {
      const user = options.userId();
      if (!user) return null;
      const id = `${name}:${user}`;
      const preferences = parseEnvelope(
        local.getItem(preferenceKey(name, user)),
      );
      const durable = await readDurable(indexedDb, id);
      if (options.userId() !== user) return null;
      if (preferences || durable) {
        return serializeMerged(preferences, durable);
      }

      const userLegacy = local.getItem(id);
      const ownerLegacy = options.isLegacyOwner() ? local.getItem(name) : null;
      const legacyRaw = userLegacy ?? ownerLegacy;
      const legacy = parseEnvelope(legacyRaw);
      if (!legacy) return null;

      await persistSplit(indexedDb, local, name, user, legacy);
      if (options.userId() !== user) return null;
      local.removeItem(id);
      if (ownerLegacy && ownerLegacy === legacyRaw) local.removeItem(name);
      return JSON.stringify(legacy);
    },

    async setItem(name, value) {
      const user = options.userId();
      if (!user) return;
      const envelope = parseEnvelope(value);
      if (!envelope) return;
      await persistSplit(indexedDb, local, name, user, envelope);
    },

    async removeItem(name) {
      const user = options.userId();
      if (!user) return;
      local.removeItem(preferenceKey(name, user));
      local.removeItem(`${name}:${user}`);
      await deleteDurable(indexedDb, `${name}:${user}`);
    },
  };
}

async function persistSplit(
  indexedDb: IDBFactory,
  local: Storage,
  name: string,
  user: string,
  envelope: Envelope,
) {
  const preferences: Record<string, unknown> = {};
  const durable: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(envelope.state)) {
    (DURABLE_FIELDS.has(key) ? durable : preferences)[key] = value;
  }
  const version = envelope.version;
  const versionField = version === undefined ? {} : { version };
  await writeDurable(indexedDb, `${name}:${user}`, {
    state: durable,
    ...versionField,
  });
  local.setItem(
    preferenceKey(name, user),
    JSON.stringify({ state: preferences, ...versionField }),
  );
}

function serializeMerged(
  preferences: Envelope | null,
  durable: Envelope | null,
): string | null {
  if (!preferences && !durable) return null;
  const version = preferences?.version ?? durable?.version;
  return JSON.stringify({
    state: { ...(preferences?.state ?? {}), ...(durable?.state ?? {}) },
    ...(version === undefined ? {} : { version }),
  });
}

function preferenceKey(name: string, user: string) {
  return `${name}:preferences:${user}`;
}

function parseEnvelope(value: string | null): Envelope | null {
  if (!value) return null;
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return null;
    }
    const envelope = parsed as Record<string, unknown>;
    const state = envelope.state;
    if (!state || typeof state !== "object" || Array.isArray(state))
      return null;
    return {
      state: state as Record<string, unknown>,
      ...(typeof envelope.version === "number"
        ? { version: envelope.version }
        : {}),
    };
  } catch {
    return null;
  }
}

function openDatabase(indexedDb: IDBFactory): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDb.open(DATABASE, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () =>
      reject(request.error ?? new Error("IndexedDB open failed"));
  });
}

async function readDurable(indexedDb: IDBFactory, key: string) {
  const db = await openDatabase(indexedDb);
  try {
    return await new Promise<Envelope | null>((resolve, reject) => {
      const request = db
        .transaction(STORE, "readonly")
        .objectStore(STORE)
        .get(key);
      request.onsuccess = () => {
        const value = request.result as Envelope | undefined;
        resolve(value ?? null);
      };
      request.onerror = () =>
        reject(request.error ?? new Error("IndexedDB read failed"));
    });
  } finally {
    db.close();
  }
}

async function writeDurable(
  indexedDb: IDBFactory,
  key: string,
  value: Envelope,
) {
  const db = await openDatabase(indexedDb);
  try {
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction(STORE, "readwrite");
      transaction.objectStore(STORE).put(value, key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () =>
        reject(transaction.error ?? new Error("IndexedDB write failed"));
      transaction.onabort = () =>
        reject(transaction.error ?? new Error("IndexedDB write aborted"));
    });
  } finally {
    db.close();
  }
}

async function deleteDurable(indexedDb: IDBFactory, key: string) {
  const db = await openDatabase(indexedDb);
  try {
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction(STORE, "readwrite");
      transaction.objectStore(STORE).delete(key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () =>
        reject(transaction.error ?? new Error("IndexedDB delete failed"));
    });
  } finally {
    db.close();
  }
}
