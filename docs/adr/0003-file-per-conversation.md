# ADR-0003: One file per conversation, not UserDefaults

## STATUS

Accepted

## CONTEXT

Conversations were originally stored in UserDefaults as a single
property-list blob. iOS rewrites the entire plist on every change. With one
chat carrying 2.3 MB of attachments, every save — each streamed reply, each
background sync — rewrote 3 MB. `cfprefsd` wrote 4.3 GB in a day on the
person's iPhone, past iOS's limit, and the app stalled.

## DECISION

Each conversation is stored in its own file in Application
Support/Conversations. Only the conversation that changed is rewritten.
The old blob is still read on launch and rewritten in the split form on
the first successful save.

## EVIDENCE

- `ConversationStorage.swift` — `FileConversationStorage` class with
  `standardDirectory` = Application Support/Conversations
- `ConversationArchive.swift` — `blobKey`, `indexKey`, `recordKey(for:)`,
  blob→split migration in `load(from:)`
- `ConversationStorage.swift` — `adopt(_:from:)` migration from UserDefaults
  to file storage with byte-for-byte verification
- Comment in `ConversationStorage.swift`: "They used to live in
  UserDefaults, which iOS keeps as a single property list and rewrites
  whole on every change."
- `ConversationPersistenceTests.testALegacyBlobOpensAndTheNextSaveStoresEachChatOnItsOwn`

## ALTERNATIVES CONSIDERED

A database (Core Data, SwiftData, SQLite) was considered. The
architecture.md says: "A future move to a database must include migration
and recovery tests." The file-per-conversation approach was chosen because
it is simple, debuggable and atomic at the conversation level.

## WHY THIS APPROACH EXISTS

UserDefaults rewrites the entire plist on every change. A file-per-key
approach costs only that key's bytes when it changes. The migration from
UserDefaults to files preserves the old storage as a fallback, and the
write order (records → index → blob removal) provides crash recovery.

## CONSEQUENCES

- A save costs only the changed conversation's bytes.
- The storage can be inspected file-by-file for debugging.
- Atomic writes prevent partial files.
- The blob→split migration is transparent and verified.
- The old blob is a recovery path until the split form is written.

## RISKS

- Many conversations mean many files (iOS handles this well).
- No concurrent-write guard (mitigated by main-actor serialization).
- No checksum (disk corruption after write is undetected).

## WHEN TO REVISIT

If conversations grow very large or need complex queries, a database
would be appropriate. The migration must include tests for backward
compatibility, crash recovery and data integrity.
