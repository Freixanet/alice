import { beforeAll, describe, expect, it } from "vitest";
import type { Sql } from "./db";
import type { EncryptedSyncRecord } from "./sync-contracts";

let sql: Sql;
let push: typeof import("./sync-store.server").pushEncryptedSyncRecords;
let pull: typeof import("./sync-store.server").pullEncryptedSyncRecords;

beforeAll(async () => {
  process.env.ALICE_PGLITE_MEMORY = "1";
  sql = await (await import("./db")).getSql();
  ({ pushEncryptedSyncRecords: push, pullEncryptedSyncRecords: pull } =
    await import("./sync-store.server"));
}, 30_000);

function record(
  id: string,
  wallTime: number,
  ciphertext: string,
): EncryptedSyncRecord {
  return {
    id,
    kind: "conversation",
    clock: { wallTime, counter: 0, deviceId: "device-a" },
    tombstone: false,
    payload: {
      version: 1,
      nonce: "abcdefghijklmnop",
      ciphertext,
      checksum: `checksum_${wallTime}`,
    },
    byteSize: ciphertext.length,
  };
}

describe("encrypted sync store", () => {
  it("keeps the first account verifier when another device tries to replace it", async () => {
    const userId = crypto.randomUUID();
    const first = {
      ...record("verifier:v1", 1, "firstkey"),
      kind: "verifier" as const,
    };
    const replacement = {
      ...record("verifier:v1", 100, "otherkey"),
      kind: "verifier" as const,
    };
    expect(
      (await push(sql, userId, crypto.randomUUID(), [first])).accepted,
    ).toBe(1);
    expect(
      (await push(sql, userId, crypto.randomUUID(), [replacement])).accepted,
    ).toBe(0);
    const stored = await pull(sql, userId, 0, 100);
    expect(stored.records[0]?.payload.ciphertext).toBe("firstkey");
  });

  it("isolates accounts and makes retries idempotent", async () => {
    const userA = crypto.randomUUID();
    const userB = crypto.randomUUID();
    const requestId = crypto.randomUUID();
    const first = await push(sql, userA, requestId, [
      record("same", 1, "aaaa"),
    ]);
    const replay = await push(sql, userA, requestId, [
      record("same", 2, "bbbb"),
    ]);
    await push(sql, userB, crypto.randomUUID(), [record("same", 3, "cccc")]);

    expect(first).toEqual({ replayed: false, accepted: 1 });
    expect(replay).toEqual({ replayed: true, accepted: 0 });
    expect((await pull(sql, userA, 0, 100)).records).toHaveLength(1);
    expect((await pull(sql, userB, 0, 100)).records).toHaveLength(1);
    expect((await pull(sql, "another-user", 0, 100)).records).toEqual([]);
  });

  it("keeps the deterministic winner when updates arrive out of order", async () => {
    const userId = crypto.randomUUID();
    await push(sql, userId, crypto.randomUUID(), [record("chat", 20, "newer")]);
    const stale = await push(sql, userId, crypto.randomUUID(), [
      record("chat", 10, "older"),
    ]);
    const result = await pull(sql, userId, 0, 100);

    expect(stale.accepted).toBe(0);
    expect(result.records).toHaveLength(1);
    expect(result.records[0]?.payload.ciphertext).toBe("newer");
  });
});
