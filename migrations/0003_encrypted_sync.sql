-- Optional end-to-end encrypted cloud synchronization.
-- Only opaque ciphertext and conflict-resolution metadata are stored here.

create sequence if not exists alice_sync_revision_seq;

create table if not exists alice_sync_record (
  user_id text not null,
  record_id text not null,
  kind text not null check (kind in ('conversation', 'attachment')),
  clock_wall_time bigint not null check (clock_wall_time >= 0),
  clock_counter integer not null check (clock_counter >= 0),
  clock_device_id text not null,
  tombstone boolean not null,
  crypto_version integer not null check (crypto_version = 1),
  nonce text not null,
  ciphertext text not null,
  checksum text not null,
  byte_size bigint not null check (byte_size >= 0 and byte_size <= 14000000),
  revision bigint not null default nextval('alice_sync_revision_seq'),
  updated_at timestamptz not null default now(),
  primary key (user_id, record_id)
);

create index if not exists alice_sync_record_user_revision_idx
  on alice_sync_record (user_id, revision);

create table if not exists alice_sync_request (
  user_id text not null,
  request_id text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, request_id)
);

create index if not exists alice_sync_request_created_idx
  on alice_sync_request (created_at);
