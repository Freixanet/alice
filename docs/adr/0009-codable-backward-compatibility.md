# ADR-0009: Codable backward compatibility with optional fields and standing tests

## STATUS

Accepted

## CONTEXT

Alice's conversations are persisted as JSON via Swift's `Codable`. When a
new field is added to a `Codable` struct, the synthesized decoder requires
that field to be present in the JSON. A default value on a non-optional
property (`var localOnly: Bool = false`) does NOT make the decoder tolerant
of a missing key — it still throws `keyNotFound`.

This exact regression erased every conversation on the person's phone: a
new `localOnly` field was added, the decoder threw on old archives, the
loader swallowed the error with `try?`, started empty, and the next save
wrote the empty result over every conversation.

## DECISION

Every new persisted field must be optional (or have a custom decoder that
supplies a default for missing keys). Standing tests guard against the
regression: `ConversationMigrationTests` contains the exact failure case as
a permanent guard. Unreadable archives are retained (salvage path), never
overwritten with an empty one.

## EVIDENCE

- `ios/AliceTests/ConversationMigrationTests.swift` — the standing guard:
  `testAMessageWithoutLocalOnlyDoesNotThrowKeyNotFound`
- `ConversationArchive.swift` — `load(from:)` returns `.unreadable(reason:bytes:)`
  instead of `.empty` on decode failure
- `ConversationArchive.swift` — `salvageKey` retains unreadable bytes
- `docs/MIGRATIONS.md` — documents the rule: "Every new persisted field
  must be optional."
- `ios/AliceTests/ForwardCompatibilityTests.swift` — documents the
  load → re-save stripping of unknown fields

## ALTERNATIVES CONSIDERED

A schema version number on each record would allow explicit migration
logic. This was not implemented because the optional-field approach is
simpler and sufficient for additive changes. A schema version would be
needed for breaking changes (field removal, type changes).

## WHY THIS APPROACH EXISTS

Swift's synthesized `Codable` is not backward-compatible by default. A
default value on a non-optional property does not help the decoder. The
regression that erased the phone's conversations is the motivating
evidence. The solution is to make every new field optional, so the
decoder supplies `nil` for missing keys.

## CONSEQUENCES

- New fields are always optional, which means they need nil-checks at use
  sites.
- Old archives are always readable.
- The standing test catches the exact regression before it ships.
- Unreadable archives are retained for recovery.

## RISKS

- A field that should not be optional must still be optional in the
  struct, with a computed property that supplies a default.
- Removed fields (from a future build) will be silently dropped on
  re-save through an older build (documented in ForwardCompatibilityTests).

## WHEN TO REVISIT

If a breaking schema change is needed (field type change, field removal),
a schema version number and explicit migration logic would be required.
The current approach only supports additive changes.
