-- The client uses an encrypted verifier to validate recovery keys, but the
-- original sync schema only admitted conversation and attachment records.
-- Extend existing databases without changing or discarding their ciphertext.
alter table alice_sync_record
  drop constraint alice_sync_record_kind_check;
alter table alice_sync_record
  add constraint alice_sync_record_kind_check
  check (kind in ('conversation', 'attachment', 'verifier'));
