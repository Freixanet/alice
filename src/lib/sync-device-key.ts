const DATABASE = "alice-sync-keys-v1";
const STORE = "device-keys";

type DeviceKeyRecord = {
  wrappingKey: CryptoKey;
  nonce: Uint8Array;
  wrappedMaster: ArrayBuffer;
};

export async function saveMasterSecretForDevice(
  userId: string,
  master: Uint8Array,
  options: { indexedDb?: IDBFactory; cryptoApi?: Crypto } = {},
) {
  const indexedDb = options.indexedDb ?? globalThis.indexedDB;
  const cryptoApi = options.cryptoApi ?? globalThis.crypto;
  const wrappingKey = await cryptoApi.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
  const nonce = cryptoApi.getRandomValues(new Uint8Array(12));
  const wrappedMaster = await cryptoApi.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: nonce,
      additionalData: associatedData(userId),
      tagLength: 128,
    },
    wrappingKey,
    Uint8Array.from(master),
  );
  await writeRecord(indexedDb, userId, { wrappingKey, nonce, wrappedMaster });
}

export async function loadMasterSecretForDevice(
  userId: string,
  options: { indexedDb?: IDBFactory; cryptoApi?: Crypto } = {},
): Promise<Uint8Array | null> {
  const indexedDb = options.indexedDb ?? globalThis.indexedDB;
  const cryptoApi = options.cryptoApi ?? globalThis.crypto;
  const record = await readRecord(indexedDb, userId);
  if (!record) return null;
  try {
    const master = await cryptoApi.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: Uint8Array.from(record.nonce),
        additionalData: associatedData(userId),
        tagLength: 128,
      },
      record.wrappingKey,
      record.wrappedMaster,
    );
    const bytes = new Uint8Array(master);
    return bytes.byteLength === 32 ? bytes : null;
  } catch {
    return null;
  }
}

export async function forgetMasterSecretForDevice(
  userId: string,
  indexedDb: IDBFactory = globalThis.indexedDB,
) {
  const db = await openDatabase(indexedDb);
  try {
    await transactionDone(db, (store) => store.delete(userId));
  } finally {
    db.close();
  }
}

function associatedData(userId: string) {
  return new TextEncoder().encode(`alice-device-master:${userId}:v1`);
}

async function writeRecord(
  indexedDb: IDBFactory,
  userId: string,
  value: DeviceKeyRecord,
) {
  const db = await openDatabase(indexedDb);
  try {
    await transactionDone(db, (store) => store.put(value, userId));
  } finally {
    db.close();
  }
}

async function readRecord(indexedDb: IDBFactory, userId: string) {
  const db = await openDatabase(indexedDb);
  try {
    return await new Promise<DeviceKeyRecord | null>((resolve, reject) => {
      const request = db
        .transaction(STORE, "readonly")
        .objectStore(STORE)
        .get(userId);
      request.onsuccess = () =>
        resolve((request.result as DeviceKeyRecord | undefined) ?? null);
      request.onerror = () =>
        reject(request.error ?? new Error("Device key read failed"));
    });
  } finally {
    db.close();
  }
}

function openDatabase(indexedDb: IDBFactory): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDb.open(DATABASE, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE)) {
        request.result.createObjectStore(STORE);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () =>
      reject(request.error ?? new Error("Device key database failed"));
  });
}

async function transactionDone(
  db: IDBDatabase,
  mutate: (store: IDBObjectStore) => IDBRequest,
) {
  await new Promise<void>((resolve, reject) => {
    const transaction = db.transaction(STORE, "readwrite");
    mutate(transaction.objectStore(STORE));
    transaction.oncomplete = () => resolve();
    transaction.onerror = () =>
      reject(transaction.error ?? new Error("Device key write failed"));
    transaction.onabort = () =>
      reject(transaction.error ?? new Error("Device key write aborted"));
  });
}
