import type { Sql } from "./db";
import type { EncryptedSyncRecord } from "./sync-contracts";

export const CLOUD_SYNC_QUOTA_BYTES = 250 * 1024 * 1024;

type StoredRow = {
  record_id: string;
  kind: EncryptedSyncRecord["kind"];
  clock_wall_time: number;
  clock_counter: number;
  clock_device_id: string;
  tombstone: boolean;
  crypto_version: 1;
  nonce: string;
  ciphertext: string;
  checksum: string;
  byte_size: number;
  revision: number;
};

export class SyncQuotaError extends Error {
  constructor() {
    super("cloud_sync_quota_exceeded");
    this.name = "SyncQuotaError";
  }
}

export async function pushEncryptedSyncRecords(
  sql: Sql,
  userId: string,
  requestId: string,
  records: EncryptedSyncRecord[],
) {
  return sql.transaction(async (tx) => {
    await tx.query("select pg_advisory_xact_lock(hashtext($1))", [userId]);
    await tx.query(
      `delete from alice_sync_request
       where user_id = $1 and created_at < now() - interval '30 days'`,
      [userId],
    );
    const inserted = await tx.query<{ request_id: string }>(
      `insert into alice_sync_request (user_id, request_id)
       values ($1, $2) on conflict do nothing returning request_id`,
      [userId, requestId],
    );
    if (!inserted.length) return { replayed: true, accepted: 0 };

    let accepted = 0;
    for (const record of records) {
      const rows = await tx.query<{ record_id: string }>(
        `insert into alice_sync_record (
           user_id, record_id, kind, clock_wall_time, clock_counter,
           clock_device_id, tombstone, crypto_version, nonce, ciphertext,
           checksum, byte_size
         ) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
         on conflict (user_id, record_id) do update set
           kind = excluded.kind,
           clock_wall_time = excluded.clock_wall_time,
           clock_counter = excluded.clock_counter,
           clock_device_id = excluded.clock_device_id,
           tombstone = excluded.tombstone,
           crypto_version = excluded.crypto_version,
           nonce = excluded.nonce,
           ciphertext = excluded.ciphertext,
           checksum = excluded.checksum,
           byte_size = excluded.byte_size,
           revision = nextval('alice_sync_revision_seq'),
           updated_at = now()
         where (excluded.clock_wall_time, excluded.clock_counter, excluded.clock_device_id,
                excluded.tombstone::int, excluded.checksum)
             > (alice_sync_record.clock_wall_time, alice_sync_record.clock_counter,
                alice_sync_record.clock_device_id, alice_sync_record.tombstone::int,
                alice_sync_record.checksum)
         returning record_id`,
        [
          userId,
          record.id,
          record.kind,
          record.clock.wallTime,
          record.clock.counter,
          record.clock.deviceId,
          record.tombstone,
          record.payload.version,
          record.payload.nonce,
          record.payload.ciphertext,
          record.payload.checksum,
          decodedBase64UrlBytes(record.payload.ciphertext),
        ],
      );
      accepted += rows.length;
    }
    const used = await getEncryptedSyncUsage(tx, userId);
    if (used > CLOUD_SYNC_QUOTA_BYTES) throw new SyncQuotaError();
    return { replayed: false, accepted };
  });
}

export async function pullEncryptedSyncRecords(
  sql: Sql,
  userId: string,
  cursor: number,
  limit: number,
) {
  const rows = await sql.query<StoredRow>(
    `select record_id, kind, clock_wall_time, clock_counter,
            clock_device_id, tombstone, crypto_version, nonce,
            ciphertext, checksum, byte_size, revision
     from alice_sync_record
     where user_id = $1 and revision > $2
     order by revision asc limit $3`,
    [userId, cursor, limit],
  );
  return {
    records: rows.map(rowToRecord),
    cursor: rows.at(-1)?.revision ?? cursor,
    hasMore: rows.length === limit,
  };
}

export async function getEncryptedSyncUsage(sql: Sql, userId: string) {
  const [{ used = 0 } = {}] = await sql.query<{ used: number }>(
    `select coalesce(sum(byte_size), 0)::bigint as used
     from alice_sync_record where user_id = $1`,
    [userId],
  );
  return used;
}

function rowToRecord(row: StoredRow) {
  return {
    id: row.record_id,
    kind: row.kind,
    clock: {
      wallTime: row.clock_wall_time,
      counter: row.clock_counter,
      deviceId: row.clock_device_id,
    },
    tombstone: row.tombstone,
    payload: {
      version: row.crypto_version,
      nonce: row.nonce,
      ciphertext: row.ciphertext,
      checksum: row.checksum,
    },
    byteSize: row.byte_size,
    revision: row.revision,
  };
}

function decodedBase64UrlBytes(value: string) {
  return Math.floor((value.length * 3) / 4);
}
