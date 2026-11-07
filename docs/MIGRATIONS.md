# Migrations

How Alice evolves its persisted data without losing what the person already has.

**Audited at:** `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 October 2026)

Alice has four persistence surfaces, each with its own migration path:

| Surface | Storage | Migration mechanism |
| ------- | ------- | ------------------- |
| iOS conversations | One JSON file per chat in Application Support/Conversations | Codable backward compatibility + blob→split migration |
| iOS preferences | UserDefaults | Key-by-key eviction to files (`RetiredPreferences`) |
| Web/server database | Neon Postgres (production) / PGLite (local) | Ordered, additive SQL files in `migrations/` |
| Web sync state | localStorage per account | Versioned JSON objects (`version: 1`) |
| Hermes plugin memory | `<profile>/.alice/memory/*.json` | Atomic writes, versioned by schema convention |
| Hermes plugin secrets | `.env` files per profile | Atomic replacement, no versioning needed |

## Principles

1. **Never silently destroy user data.** An unreadable archive is retained, not
   overwritten with an empty one. Unreadable bytes go to a salvage key.
2. **Additive SQL migrations.** Every database migration is additive and
   backward-compatible. A code rollback must never require a destructive
   database rollback.
3. **Codable backward compatibility is not automatic.** A default on a
   non-optional Swift property does not make synthesized decoding tolerant of a
   missing key. Every new persisted field must be optional or have a custom
   decoder that supplies a default for missing keys.
4. **Write order is the recovery path.** Records are written first, then the
   index, then the old blob is removed. A crash before the index is stored
   leaves the older blob for the next launch.
5. **Atomic writes.** Every file write uses `.atomic` (iOS) or
   `tempfile + os.replace` (Python). A crash never leaves half a file.
6. **Verify before committing.** Storage migrations read back what they wrote
   and compare before removing the source. Anything short of that leaves the
   source untouched.

## iOS conversation migrations

### Migration 1: blob → split storage

- **Version:** Implicit. No version number in the blob; the presence of
  `alice.conversations.index` distinguishes split from blob.
- **Precondition:** The old `alice.conversations` blob exists in storage and
  the index key does not (or the index is empty).
- **Migration behavior:** `ConversationArchive.load(from:)` reads the index
  first. If the index is absent or unreadable, it falls back to the blob.
  The blob is decoded as `[Conversation]`. On the first successful save,
  `ConversationArchive.apply(_:to:)` writes each conversation to its own key,
  writes the index, then removes the blob.
- **Validation:** `ConversationPersistenceTests.testALegacyBlobOpensAndTheNextSaveStoresEachChatOnItsOwn`
  verifies the blob is read, the split form is written, and the blob is removed.
- **Failure behavior:** If the blob cannot be decoded, the bytes are retained
  under the salvage key (`alice.conversations.salvage`) and the app starts
  with an empty conversation list. The corrupt bytes are never overwritten.
- **Recovery:** The person can export the salvage file. A future build or a
  manual fix can attempt recovery from the retained bytes.

### Migration 2: UserDefaults → FileConversationStorage

- **Version:** Tracked by `alice.conversations.moved` marker key.
- **Precondition:** Conversations exist in UserDefaults (the old storage) and
  the `moved` marker is absent from the file storage.
- **Migration behavior:** `ConversationArchive.adopt(_:from:)` copies every
  key from UserDefaults to the file storage as raw bytes (without decoding),
  reads each back and compares, writes the marker, then removes the source
  keys from UserDefaults.
- **Validation:** Every copied key is read back and compared byte-for-byte
  before the marker is written. Source is only emptied after the marker exists.
- **Failure behavior:** If any copy fails or does not read back identical,
  the source is left untouched and the app continues reading from UserDefaults.
- **Recovery:** Re-running the migration on the next launch. The marker
  prevents double-migration; if the marker exists but source keys remain
  (interrupted after marker but before cleanup), the remaining source keys
  are removed on the next launch.

### Migration 3: Codable field additions

- **Version:** Per-field, implicit. There is no schema version number; each
  new field is optional in the Codable struct.
- **Precondition:** An archive written by a previous build is read.
- **Migration behavior:** Swift's synthesized `JSONDecoder` supplies `nil`
  for optional properties whose keys are absent. New fields must be declared
  optional (or have a default that the decoder honors — see below).
- **Validation:** `ConversationMigrationTests` contains standing guards:
  - `testAMessageWithoutLocalOnlyDoesNotThrowKeyNotFound` — the exact
    regression that erased the phone, as a permanent guard.
  - `testAnOldMessageDecodes` — an old message with no new fields decodes.
  - `testTheWholeOldArchiveLoadsWithNothingLost` — a complete old archive
    survives intact.
  - `testAnOldArchiveSurvivesReEncoding` — round-trip preserves all data.
- **Failure behavior:** If decoding throws, the conversation is placed in
  the `Skipped` list with its reason and raw bytes. The app starts with the
  conversations that did decode. Skipped bytes are available for recovery.
- **Recovery:** The `Skipped` entries retain their raw `Data`. A future build
  can attempt a more tolerant decode.

**Critical rule:** Adding a non-optional property without a default breaks
decoding of every existing archive. The regression that erased all
conversations on the phone was caused by `var localOnly: Bool = false` —
the default does not help the synthesized decoder. Every new persisted
field must be optional.

## SQL migrations

### Mechanism

Migrations live in `migrations/` as ordered, numbered SQL files. They are
the single source of truth for the database schema. Applied files are
recorded by name in a `_migrations` table and never run again.

Production (Neon) applies them through `npm run db:migrate`. Local PGLite
applies them automatically on startup.

### Existing migrations

| File | What it does |
| ---- | ------------ |
| `0001_auth.sql` | Better Auth schema (user, session, account, verification). Generated by Better Auth CLI — do not edit by hand. |
| `0002_hermes_gate.sql` | Per-user Hermes connection (url + key), sealed. |
| `0003_encrypted_sync.sql` | E2E encrypted sync records (ciphertext + conflict metadata). |
| `0004_security_hardening.sql` | Cross-instance rate limiting. |
| `0005_sync_verifier.sql` | Extends sync record kinds to include `verifier` (additive constraint change). |

### Rules for new SQL migrations

1. **Additive only.** New tables, new columns with defaults, new indexes.
   Never `DROP TABLE`, `DROP COLUMN` or destructive `ALTER` in a migration
   that a code rollback cannot tolerate.
2. **Backward-compatible constraint changes.** `0005` demonstrates the
   pattern: drop the old check constraint and add the expanded one. The
   new constraint must accept everything the old one did.
3. **Never edit an applied migration.** If a migration has been applied to
   any database, it is immutable. Fix forward with a new numbered file.
4. **Never remove records to make a migration pass.** If existing data
   violates a new constraint, write a data migration first (a separate
   numbered file that transforms the data), then add the constraint.
5. **Test with both PGLite and Neon.** PGLite applies automatically; Neon
   requires `npm run db:migrate`. Both must succeed.

## Web sync state migrations

### Mechanism

Sync state is a versioned JSON object in localStorage:

```typescript
type PersistedAccountSyncState = {
  version: 1;
  initialized: boolean;
  pending: Record<string, SyncPendingEntry>;
  conversationVersions: Record<string, number>;
  lastSyncedAt: number | null;
};
```

### Migration behavior

`loadSyncAccountState` reads the raw JSON, parses it defensively (rejecting
non-integer versions, non-boolean tombstones, non-object shapes), and
returns a normalized state. If parsing fails entirely, it returns the empty
state.

### Rules for new sync state versions

1. **Bump `version`.** A new version number triggers a migration function
   that transforms the old shape to the new one.
2. **Defensive parsing.** Every field is validated before use. Unknown
   fields are silently dropped.
3. **Account-scoped.** State is keyed by user ID. An account change
   cancels work from the old account.

## Hermes plugin memory migrations

### Mechanism

The memory keeper stores its own metadata in `<profile>/.alice/memory/`:

- `entries.json` — entry origins (who wrote what, when)
- `changes.json` — every change made, with full text of what was removed
- `settings.json` — whether cleanup may apply
- `declined.json` — proposals the person rejected

### Migration behavior

Each file is read with `_read(name, default)`, which returns the default
on any `OSError` or `ValueError`. If the file does not exist, it starts
empty. There is no explicit version number; the schema is forward-compatible
by convention (new fields are optional, unknown fields are ignored).

### Rules

1. **Atomic writes.** Every write goes through `_write(name, data)`, which
   writes to a `.tmp` file and uses `os.replace` to swap it in.
2. **Bounded growth.** `changes.json` is capped at `MAX_CHANGES = 500`
   entries.
3. **Reversible.** Every change is logged with the full text of what was
   removed, so it can be reverted. A revert is itself logged.

## Migration test requirements

Every migration mechanism must have:

1. **A fixture that represents the old format.** Use real-shaped data, not
   trivially small examples.
2. **A test that the old format loads.** The exact regression that motivated
   the migration should be a standing guard.
3. **A round-trip test.** Old format → load → save → load again → equal.
4. **A corrupt-data test.** Unreadable bytes are retained, not destroyed.
5. **A recovery test.** The recovery path (salvage, fallback, revert) works.

## Failure scenarios and recovery

| Scenario | What happens | Recovery |
| -------- | ------------ | -------- |
| Crash mid-write (iOS) | Atomic write leaves no partial file. The old file is intact. | None needed; next read gets the old file. |
| Crash mid-migration (blob→split) | The blob is still there. The index may be partial. | Next launch reads the blob (index absent or incomplete). |
| Crash mid-migration (UserDefaults→file) | Source is untouched until all copies are verified. | Next launch re-runs the migration. |
| Crash mid-SQL-migration | The migration is recorded in `_migrations` only after success. | Next startup re-runs the incomplete migration. |
| Codable field added without optional | Decoding throws `keyNotFound`. Conversation is skipped, bytes retained. | Fix the field to optional, rebuild, relaunch. |
| Corrupt JSON file (iOS) | `ConversationArchive.loadSplit` skips the conversation, retains bytes. | Bytes in `Skipped` list; manual recovery possible. |
| Corrupt JSON file (plugin) | `_read` returns the default. The file is not overwritten. | Restore from backup or accept the default. |
| Application downgrade | Old build reads new-format archives. New optional fields are ignored. | Works as long as the old build's Codable structs are a subset. |
| Application downgrade (SQL) | Old code connects to a database with extra columns/constraints. | Works as long as migrations were additive. |
