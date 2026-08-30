import { describe, expect, it } from "vitest";
import {
  decodeRecoveryPhrase,
  decryptPayload,
  deriveContentKey,
  encodeRecoveryPhrase,
  encryptPayload,
  generateMasterSecret,
} from "./sync-crypto";

describe("end-to-end sync encryption", () => {
  it("round-trips a recovery phrase without reducing entropy", () => {
    const secret = generateMasterSecret();
    expect(decodeRecoveryPhrase(encodeRecoveryPhrase(secret))).toEqual(secret);
  });

  it("binds ciphertext to its record and account scope", async () => {
    const secret = generateMasterSecret();
    const key = await deriveContentKey(secret, "account-a");
    const payload = await encryptPayload({ text: "private" }, key, "record-a");
    await expect(decryptPayload(payload, key, "record-a")).resolves.toEqual({
      text: "private",
    });
    await expect(decryptPayload(payload, key, "record-b")).rejects.toThrow();
    const otherKey = await deriveContentKey(secret, "account-b");
    await expect(
      decryptPayload(payload, otherKey, "record-a"),
    ).rejects.toThrow();
  });

  it("detects authenticated ciphertext corruption", async () => {
    const key = await deriveContentKey(generateMasterSecret(), "account-a");
    const payload = await encryptPayload("private", key, "record-a");
    const first = payload.ciphertext[0] === "a" ? "b" : "a";
    await expect(
      decryptPayload(
        { ...payload, ciphertext: first + payload.ciphertext.slice(1) },
        key,
        "record-a",
      ),
    ).rejects.toThrow();
  });
});
