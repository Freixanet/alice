# Alice Rollback

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document audits Alice's ability to safely reverse a bad change. The goal:
Alice should never require a forward-only emergency patch merely because a
previous change cannot be reversed.

## Rollback matrix

### Source code

**Can it be rolled back?** Yes — `git revert` or `git reset`.

**What state may become incompatible?** Nothing. Source code is stateless.

**What must be versioned?** Every commit (already done via git).

**What must remain backward compatible temporarily?** Nothing for source
alone. Compatibility matters only for persisted data (see below).

**What could cause data loss?** Nothing from a code revert.

**Minimum required safeguard:** Review the diff before merging. CI must pass.

### Configuration

**Can it be rolled back?** Partially.

**What state may become incompatible?**
- `~/.hermes/` config changes (profile, model, fallback) are not versioned.
- `.env` changes are not tracked.
- Vercel env vars are versioned in Vercel's dashboard.

**What must be versioned?**
- `.env.example` is tracked in git (template only).
- `vercel.json` is tracked.
- `ios/project.yml` is tracked (Xcode project is generated, not committed).

**What must remain backward compatible temporarily?** Configuration that
affects persisted data (e.g., changing a profile name invalidates session
references).

**What could cause data loss?** Deleting a Hermes profile destroys its
sessions, memory, and vault.

**Minimum required safeguard:** Back up `~/.hermes/` before config changes.
The `scripts/backup-alice.sh` script does this.

### Dependencies

**Can it be rolled back?** Yes — `package-lock.json` pins exact versions.
`npm ci` reproduces the exact dependency tree.

**What state may become incompatible?** A newer dependency may have migrated
data in an incompatible format (rare for dev dependencies).

**What must be versioned?** `package-lock.json`, `skills-lock.json`.

**What must remain backward compatible temporarily?** Swift package versions
(ios/project.yml pins these). Python dependencies in the plugin are pinned
(`pypdf==6.18.0`).

**What could cause data loss?** None directly.

**Minimum required safeguard:** `npm ci` (not `npm install`). Pin all
versions. Run `npm audit` before release.

### iOS application

**Can it be rolled back?** Yes — rebuild from a previous commit. Build numbers
only go up (`CURRENT_PROJECT_VERSION`).

**What state may become incompatible?**
- Codable archives: newer app versions may write data that older versions
  cannot read. The contract is: read old archives before extending; retain
  unreadable bytes rather than overwriting with empty data.
- Keychain credentials: format is stable.

**What must be versioned?** Build number (monotonic). `ALICE_SOURCE_REVISION`
(identifies the git commit in the built app).

**What must remain backward compatible temporarily?** Persisted Swift Codable
types. A new property with a default value does NOT make synthesized decoding
backward-compatible — old archives without the key will fail. Use
`decodeIfPresent` for new fields.

**What could cause data loss?** Replacing an unreadable archive with an empty
one. This is explicitly forbidden by the AGENTS.md contract.

**Minimum required safeguard:** Test Codable backward compatibility. Never
overwrite unreadable data. See [MIGRATIONS](MIGRATIONS.md) for the policy.

### Mac/backend (Hermes)

**Can it be rolled back?** Hermes itself can be updated or downgraded with
`hermes update`. The Alice plugin can be restored from backup.

**What state may become incompatible?**
- Hermes database schema changes between versions.
- Plugin API changes may not be backward-compatible with older Hermes.

**What must be versioned?** Plugin code (in git), Hermes version (in
compatibility matrix).

**What must remain backward compatible temporarily?** The plugin uses only
official Hermes hooks. A Hermes update should not overwrite the plugin.

**What could cause data loss?** Downgrading Hermes could lose data if the
database schema changed.

**Minimum required safeguard:** Back up `~/.hermes/` before Hermes updates.
The plugin install script backs up the existing plugin before replacing.

### Persistence/schema

**Can it be rolled back?** Database migrations are additive and
backward-compatible (per `docs/release-operations.md`). A code rollback must
never require a destructive database rollback.

**What state may become incompatible?** A migration that adds a column is
safe to roll back from (old code ignores the column). A migration that removes
or renames a column is NOT safe.

**What must be versioned?** Migration files (in `migrations/`, tracked in git).
The `_migrations` table records applied state.

**What must remain backward compatible temporarily?** Old application code
must continue to work against a database that has new migrations applied.

**What could cause data loss?** A migration that drops data. This is
explicitly forbidden by the migration policy.

**Minimum required safeguard:** See [MIGRATIONS](MIGRATIONS.md).

### iPhone ↔ Mac protocol

**Can it be rolled back?** Partially. The protocol is versioned (`v=1` in QR),
but streaming events and dashboard RPC methods are not individually versioned.

**What state may become incompatible?**
- A new event type is safe (unknown events are preserved).
- A removed or renamed event type breaks older clients.
- A changed response format breaks older clients.

**What must be versioned?** Protocol version (`v` in QR), capability
manifest, Hermes version in compatibility matrix.

**What must remain backward compatible temporarily?** New fields in responses
are allowed (ignored by older clients). Removed/renamed fields are breaking
changes.

**What could cause data loss?** A protocol change that causes Alice to
misinterpret a response could corrupt conversation state.

**Minimum required safeguard:** See [PROTOCOL](PROTOCOL.md) for the full
compatibility rules. Capability detection gates new features.

### Plugin changes

**Can it be rolled back?** Yes — the plugin install script can be re-run from
a previous commit. The old plugin is backed up before replacement (per
AGENTS.md).

**What state may become incompatible?** Plugin data stored in Hermes
databases may use formats that an older plugin cannot read.

**What must be versioned?** Plugin code (in git).

**What must remain backward compatible temporarily?** Plugin endpoints that
the iOS app depends on must not change format without a version bump.

**What could cause data loss?** Plugin data corruption during a deploy.

**Minimum required safeguard:** Back up `~/.hermes/plugins/alice/` before
deploying. The AGENTS.md checklist requires this.

### External-service configuration

**Can it be rolled back?** Yes — model provider keys, Vercel env vars, Neon
config can be changed back.

**What state may become incompatible?** If a provider API changes, old code
may not work. Fallback providers mitigate this.

**What must be versioned?** Provider configuration in Hermes profile `.env`.

**What must remain backward compatible temporarily?** Provider API
compatibility (Alice uses standard OpenAI-compatible APIs where possible).

**What could cause data loss?** None directly.

**Minimum required safeguard:** Configure fallback providers. Document
provider credentials (see [OPERATIONS](OPERATIONS.md)).

### Deployment changes

**Can it be rolled back?** Yes — Vercel deployments are immutable. The
production alias can be pointed at a previous deployment without rebuilding.

**What state may become incompatible?** A database migration applied during
deploy cannot be rolled back if it's destructive. But migrations are additive
(see [MIGRATIONS](MIGRATIONS.md)).

**What must be versioned?** Deployment URL, version (from `X-Alice-Version`
header).

**What must remain backward compatible temporarily?** A rolled-back
deployment must work against the current database schema.

**What could cause data loss?** None if migrations are additive.

**Minimum required safeguard:** Run `npm run release:verify` after deploy.
See [release-operations](release-operations.md) for the full rollback procedure.

## Rollback procedure summary

| Change type       | How to roll back                          | Time to recover |
| ----------------- | ------------------------------------------ | --------------- |
| Source code       | `git revert <commit>`                      | Minutes         |
| Web deployment    | Promote previous Vercel deployment         | Minutes         |
| iOS app           | Rebuild from previous commit, install     | 10-15 minutes   |
| Database migration| Not needed (additive only)                | N/A             |
| Hermes plugin     | Restore from `~/.hermes/backups/`          | Minutes         |
| Config change     | Restore from backup or manual revert       | Minutes         |
| Dependency        | `git checkout -- package-lock.json && npm ci` | Minutes     |
| Protocol change   | Update both sides to compatible version    | Hours           |
