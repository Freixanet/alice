import { describe, expect, it } from "vitest";
import { syncRequestSchema } from "./sync-contracts";

const record = {
  id: "conversation:one",
  kind: "conversation" as const,
  clock: { wallTime: 1, counter: 0, deviceId: "device-a" },
  tombstone: false,
  payload: {
    version: 1 as const,
    nonce: "abcdefghijklmnop",
    ciphertext: "opaque_ciphertext",
    checksum: "checksum",
  },
  byteSize: 17,
};

describe("sync request contract", () => {
  it("accepts an encrypted idempotent push", () => {
    expect(
      syncRequestSchema.parse({
        action: "push",
        requestId: "7783e3c4-6195-4f10-85bd-10880c127a27",
        records: [record],
      }),
    ).toMatchObject({ action: "push", records: [{ id: record.id }] });
  });

  it("rejects plaintext and unknown fields", () => {
    expect(
      syncRequestSchema.safeParse({
        action: "push",
        requestId: "7783e3c4-6195-4f10-85bd-10880c127a27",
        records: [{ ...record, plaintext: "must never reach the server" }],
      }).success,
    ).toBe(false);
  });

  it("bounds pull cursors and batches", () => {
    expect(
      syncRequestSchema.safeParse({ action: "pull", cursor: "12", limit: 200 })
        .success,
    ).toBe(true);
    expect(
      syncRequestSchema.safeParse({ action: "pull", cursor: "-1" }).success,
    ).toBe(false);
    expect(
      syncRequestSchema.safeParse({ action: "pull", limit: 201 }).success,
    ).toBe(false);
  });
});
