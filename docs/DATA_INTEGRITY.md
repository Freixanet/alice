# Data integrity

How Alice protects the person's data against corruption, loss and
inconsistency. Companion to [MIGRATIONS.md](MIGRATIONS.md).

**Audited at:** `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 October 2026)

## Threat model

Alice is a personal app on a single phone, talking to a single Hermes on a
single Mac. The person's data is their conversations, drafts, notes, goals,
feed preferences, connection secrets and agent memory. The threats are:

1. **Interrupted writes** — the app is killed mid-save (background, crash,
   low memory).
2. **Interrupted migrations** — the app is killed while converting between
   storage formats.
3. **Corrupt records** — a file is partially written, the disk has a bad
   sector, or a Codable change makes old data unreadable.
4. **Stale cache** — cached data from a previous Hermes or account is shown
   as if it were current.
5. **Incompatible schema versions** — a newer build wrote data an older
   build cannot read, or vice versa.
6. **Duplicate records** — a sync or migration ran twice.
7. **Missing records** — a delete removed something it should not have.
8. **Local/remote divergence** — the phone and Hermes disagree about what
   happened.
9. **Sync failures** — an encrypted sync upload or download failed midway.
10. **Application downgrade** — the person installs an older build.
11. **Accidental deletion** — a destructive reset path removes everything.

## Protections in place

### Atomic writes (all surfaces)

| Surface | Mechanism | What it prevents |
| ------- | --------- | ---------------- |
| iOS conversations | `Data.write(to:options:.atomic)` | Partial file on crash |
| iOS feed | `Data.write(to:options:[.atomic, .completeFileProtectionUntilFirstUserAuthentication])` | Partial file + data protection |
| iOS launch cache | `.atomic` + `.completeFileProtectionUntilFirstUserAuthentication` | Partial file + data protection |
| iOS retired prefs | `.atomic` + `.completeFileProtectionUntilFirstUserAuthentication` | Partial file + data protection |
| Plugin memory | `tempfile` + `os.replace` | Partial file on crash |
| Plugin secrets | `tempfile` + `os.replace` + `chmod 0600` | Partial file + permission leak |
| SQL migrations | Transactional (Neon) / automatic (PGLite) | Partial schema change |

### Write-order recovery (iOS conversations)

`ConversationArchive.apply(_:to:)` writes in this order:
1. Changed conversation records
2. The index (list of conversation IDs)
3. Removal of the old blob and deleted conversations

A crash at any point leaves the previous state readable:
- Crash during step 1: old records are intact; new ones are partial or absent.
- Crash during step 2: old index is intact; new records exist but are not
  referenced by the old index (harmless until the next save).
- Crash during step 3: old blob is still there; everything works.

### Salvage path (iOS conversations)

When `ConversationArchive.load` encounters unreadable bytes:
1. The bytes are retained under `alice.conversations.salvage`.
2. The app starts with an empty (or partial) conversation list.
3. The corrupt bytes are never overwritten.
4. The person can export the salvage file for manual recovery.

### Keychain protection (iOS secrets)

`KeyStore.save` uses update-then-add, never delete-then-add:
- If the update succeeds, the old key is replaced in place.
- If the update fails (locked keychain, entitlement change), the previous
  working credential is still there.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` excludes the key from
  backups and iCloud Keychain. A restore on another phone cannot carry it.

### Scope-bound caching (iOS launch cache)

`LaunchCache` entries are tied to a `scope` (dashboard address + user) and
have a 7-day TTL. An old Mac's errands never show up against a new one.
A list left for days is not passed off as today's.

### Retired preferences (iOS)

`RetiredPreferences.moveToFiles` moves large preference values to files
before removing the key. The copy is read back and compared before the key
is removed. An interrupted move leaves the key in place.

### Sync state isolation (web)

Sync state is keyed by user ID. An account change cancels pending work
from the old account. The pull cursor is saved with the corresponding
state. Disconnection, retries and key mismatch are distinct states, not
a single on/off preference.

### Memory audit trail (Hermes plugin)

`memory_keeper.py` logs every change to `changes.json` with the full text
of what was removed. Every change can be reverted. The person's own words
(`source: "person"` or `"hand"`) are never touched by cleanup rules.

### Secret store atomicity (Hermes plugin)

`secret_store.py` writes to a tempfile, sets `0600`, then `os.replace`.
The value never appears in a message, log or reply. Only whether a name
is set is ever read back.

## Failure scenarios and their outcomes

### Crash → silent corruption

**Cannot happen.** All writes are atomic. A crash leaves the previous file
intact.

### Codable change → missing records

**Guarded against.** The standing test
`testAMessageWithoutLocalOnlyDoesNotThrowKeyNotFound` catches the exact
regression. Every new persisted field must be optional. Unreadable
conversations are retained in the `Skipped` list, not discarded.

### Interrupted migration → data loss

**Cannot happen.** Both iOS migrations (blob→split, UserDefaults→file)
verify every copy before removing the source. The SQL migration runner
records a migration as applied only after it succeeds.

### Stale cache → wrong data shown

**Mitigated.** Launch cache entries have a scope and TTL. Feed cache
survives offline but is replaced on the next successful sync. Bot chat
history is re-read from Hermes on reconnect.

### Local/remote divergence → impossible UI state

**Mitigated.** `localOnly` messages are never replayed into Hermes. The
agent's transcript is the canonical one; Alice's local copy is a view of
it. A message the agent has no record of is marked and never sent back.

### Sync failure → partial state

**Mitigated.** The pull cursor is saved with the corresponding state.
A failed upload stays in the pending queue. A failed download keeps the
last good state. Key mismatch is a distinct state, not a silent failure.

### Application downgrade → unreadable data

**Partially mitigated.** Codable archives are backward-compatible (new
optional fields are ignored by old builds). SQL migrations are additive
(old code works with extra columns). However, a build that removes a
Codable field will lose data from archives that included it. There is no
forward-compatibility guard against removed fields.

**Recovery:** Keep the last known-good build. Do not downgrade past a
migration boundary without a backup.

### Destructive reset → accidental data loss

**Current state:** The Developer screen has reset tools. These are
intentional, not accidental. A reset clears preferences and conversation
files but does not touch the Keychain (the Hermes key survives).

## What is not protected

1. **No backup.** There is no automatic backup of iOS conversation files.
   If the app container is deleted (uninstall, device wipe), conversations
   are gone. Encrypted sync (web) is the only off-device copy, and it is
   not yet available on iOS.

2. **No forward-compatibility guard.** A build that removes a Codable field
   will silently drop that field's data from existing archives on the next
   save. There is no test that catches removed fields.

3. **No checksum.** Conversation files have no checksum. A partially
   written file that happens to be valid JSON but semantically wrong will
   not be detected. The atomic write makes this unlikely but not
   impossible (disk corruption after write).

4. **No concurrent-write guard.** `FileConversationStorage` is
   `@unchecked Sendable` with no lock. If two threads write the same key
   simultaneously, the last write wins. In practice, all writes go through
   `AppStore` on the main actor, so this does not happen.

5. **No integrity check on plugin memory.** `memory_keeper.py` trusts the
   JSON files it reads. A hand-edited `entries.json` with invalid structure
   is silently replaced with the default.

## Recommended improvements (not yet implemented)

1. **Schema version on conversation records.** Add a `version` field to
   the conversation JSON. On load, if the version is newer than the build
   knows, refuse to save (preventing downgrade data loss).

2. **Checksum on conversation files.** Write a `.checksum` file alongside
   each conversation. On load, verify the checksum. If it fails, treat as
   corrupt (salvage path).

3. **Backup before migration.** Before a storage migration, copy the
   current storage to a backup directory. Keep one generation.

4. **Forward-compatibility test.** A test that loads a conversation
   archive written by a future build (with unknown fields) and verifies
   that no data is lost on re-save.
