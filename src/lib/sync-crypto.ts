const MASTER_BYTES = 32;
const NONCE_BYTES = 12;
const RECOVERY_PREFIX = "alice1";

export type EncryptedPayload = {
  version: 1;
  nonce: string;
  ciphertext: string;
  checksum: string;
};

export function generateMasterSecret(
  cryptoApi = globalThis.crypto,
): Uint8Array {
  return cryptoApi.getRandomValues(new Uint8Array(MASTER_BYTES));
}

export function encodeRecoveryPhrase(secret: Uint8Array): string {
  if (secret.byteLength !== MASTER_BYTES)
    throw new Error("Invalid master secret");
  const encoded = toBase64Url(secret);
  return `${RECOVERY_PREFIX}-${encoded.match(/.{1,4}/g)?.join(".") ?? encoded}`;
}

export function decodeRecoveryPhrase(phrase: string): Uint8Array {
  const normalized = phrase.trim();
  if (!normalized.startsWith(`${RECOVERY_PREFIX}-`)) {
    throw new Error("Invalid recovery phrase");
  }
  const secret = fromBase64Url(
    normalized.slice(RECOVERY_PREFIX.length + 1).replaceAll(".", ""),
  );
  if (secret.byteLength !== MASTER_BYTES)
    throw new Error("Invalid recovery phrase");
  return secret;
}

export async function deriveContentKey(
  master: Uint8Array,
  accountScope: string,
  cryptoApi = globalThis.crypto,
): Promise<CryptoKey> {
  if (master.byteLength !== MASTER_BYTES)
    throw new Error("Invalid master secret");
  const source = await cryptoApi.subtle.importKey(
    "raw",
    asArrayBuffer(master),
    "HKDF",
    false,
    ["deriveKey"],
  );
  return cryptoApi.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: new TextEncoder().encode(`alice-sync:${accountScope}`),
      info: new TextEncoder().encode("content:v1"),
    },
    source,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function encryptPayload(
  value: unknown,
  key: CryptoKey,
  associatedId: string,
  cryptoApi = globalThis.crypto,
): Promise<EncryptedPayload> {
  const plaintext = new TextEncoder().encode(JSON.stringify(value));
  const nonce = cryptoApi.getRandomValues(new Uint8Array(NONCE_BYTES));
  const additionalData = new TextEncoder().encode(
    `alice-record:${associatedId}:v1`,
  );
  const encrypted = await cryptoApi.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData, tagLength: 128 },
    key,
    plaintext,
  );
  const checksum = await cryptoApi.subtle.digest("SHA-256", plaintext);
  return {
    version: 1,
    nonce: toBase64Url(nonce),
    ciphertext: toBase64Url(new Uint8Array(encrypted)),
    checksum: toBase64Url(new Uint8Array(checksum)),
  };
}

export async function decryptPayload<T>(
  payload: EncryptedPayload,
  key: CryptoKey,
  associatedId: string,
  cryptoApi = globalThis.crypto,
): Promise<T> {
  if (payload.version !== 1) throw new Error("Unsupported encrypted payload");
  const additionalData = new TextEncoder().encode(
    `alice-record:${associatedId}:v1`,
  );
  const plaintext = await cryptoApi.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: asArrayBuffer(fromBase64Url(payload.nonce)),
      additionalData,
      tagLength: 128,
    },
    key,
    asArrayBuffer(fromBase64Url(payload.ciphertext)),
  );
  const bytes = new Uint8Array(plaintext);
  const checksum = new Uint8Array(
    await cryptoApi.subtle.digest("SHA-256", bytes),
  );
  if (toBase64Url(checksum) !== payload.checksum)
    throw new Error("Checksum mismatch");
  return JSON.parse(new TextDecoder().decode(bytes)) as T;
}

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}

function fromBase64Url(value: string): Uint8Array {
  if (!/^[a-zA-Z0-9_-]+$/.test(value)) throw new Error("Invalid base64url");
  const padded = value
    .replaceAll("-", "+")
    .replaceAll("_", "/")
    .padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return Uint8Array.from(bytes).buffer;
}
