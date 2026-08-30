import { z } from "zod";

const opaque = (max: number) =>
  z
    .string()
    .min(1)
    .max(max)
    .regex(/^[A-Za-z0-9_-]+$/);

export const encryptedSyncRecordSchema = z.strictObject({
  id: z.string().trim().min(1).max(160),
  kind: z.enum(["conversation", "attachment"]),
  clock: z.strictObject({
    wallTime: z.number().int().nonnegative().safe(),
    counter: z.number().int().nonnegative().max(2_147_483_647),
    deviceId: z.string().trim().min(1).max(128),
  }),
  tombstone: z.boolean(),
  payload: z.strictObject({
    version: z.literal(1),
    nonce: opaque(32),
    ciphertext: opaque(14_000_000),
    checksum: opaque(64),
  }),
  byteSize: z
    .number()
    .int()
    .nonnegative()
    .max(10 * 1024 * 1024),
});

export const syncRequestSchema = z.discriminatedUnion("action", [
  z.strictObject({
    action: z.literal("pull"),
    cursor: z.string().regex(/^\d+$/).max(20).optional(),
    limit: z.number().int().min(1).max(200).optional(),
  }),
  z.strictObject({
    action: z.literal("push"),
    requestId: z.string().uuid(),
    records: z.array(encryptedSyncRecordSchema).min(1).max(100),
  }),
  z.strictObject({ action: z.literal("quota") }),
]);

export const syncPullResponseSchema = z.strictObject({
  ok: z.literal(true),
  records: z.array(
    encryptedSyncRecordSchema.extend({
      revision: z.number().int().nonnegative().safe(),
    }),
  ),
  cursor: z.string().regex(/^\d+$/),
  hasMore: z.boolean(),
});

export const syncPushResponseSchema = z.strictObject({
  ok: z.literal(true),
  replayed: z.boolean(),
  accepted: z.number().int().nonnegative(),
});

export type EncryptedSyncRecord = z.infer<typeof encryptedSyncRecordSchema>;
export type SyncRequest = z.infer<typeof syncRequestSchema>;
