# Alice Disaster Recovery

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document analyzes disaster scenarios for Alice and defines practical,
cost-effective protections. It is not enterprise infrastructure — it is the
minimum a personal project needs to recover from real failures.

## Runtime dependency graph

```
iPhone (Alice app)
  ├── Gateway (Hermes, port 8643+, Tailscale or LAN)
  │     └── Model provider (OpenAI, Anthropic, etc.)
  ├── Dashboard (Hermes, port 9119)
  │     └── Alice plugin (~/.hermes/plugins/alice)
  │           └── Chromium (shared browser, optional)
  │           └── changedetection.io (page watches, optional)
  ├── Mac notifier (LaunchAgent, optional)
  └── Web companion (Vercel + Neon, optional)
        └── Encrypted sync (device keys, server-side verifier)
```

## Single points of failure

| Component              | SPOF? | Why                                           |
| ---------------------- | ----- | --------------------------------------------- |
| Hermes gateway         | YES   | If the gateway is down, Alice cannot chat     |
| Model provider key     | YES   | Without a model, Hermes has nothing to say    |
| Mac (physical)         | YES   | Everything runs on one machine                |
| Tailscale connection   | Partial | LAN fallback exists but is less reliable    |
| Vercel deployment      | NO    | Immutable deploys; rollback is trivial        |
| Neon database          | Partial | Local PGLite fallback works for dev          |
| Alice plugin           | Partial | Chat works without it; pairing/briefings don't |
| iPhone (physical)      | YES   | The only client; no web parity for iOS features |

## Scenario analysis

### A. Primary development Mac dies

**Impact:** Complete loss of Hermes, gateway, dashboard, plugin, notifier, and
build environment.

**Data at risk:**
- Hermes databases (`~/.hermes/` — profiles, sessions, memory, vault)
- Alice plugin configuration and skills
- Build environment (Xcode, signing keys, provisioning profiles)
- Notifier state

**Detection:** iPhone shows "Hermes unreachable." Health check fails on
gateway, dashboard, and plugin.

**Fail-safe behavior:** Alice iOS shows a clear connection error. Existing
conversations remain on the iPhone (Keychain + UserDefaults). No data loss on
the phone side.

**Recovery procedure:**
1. On a new Mac: install Xcode 26, XcodeGen, Node.js 22+, npm 11+.
2. `git clone https://github.com/Freixanet/alice.git`
3. Restore `~/.hermes/` from backup (see backup procedure below).
4. Run `hermes-plugin/install.sh`.
5. Start Hermes gateway and dashboard.
6. Re-pair the iPhone (QR or manual address + key).

**Recovery dependencies:** Backup of `~/.hermes/`, Apple developer account,
Xcode 26, Hermes 0.21.x.

**Preventive measure:** Automated backup of `~/.hermes/` (see below).

**Automation opportunity:** `scripts/backup-alice.sh` creates a tarball of
critical directories.

### B. iPhone is replaced

**Impact:** Loss of all local data: conversations, Keychain credentials,
UserDefaults, Health data.

**Data at risk:**
- Conversation archives (UserDefaults, per-conversation keys)
- Gateway/dashboard credentials (Keychain)
- App preferences
- Health data (if not synced to Apple Health cloud)

**Detection:** New iPhone has no Alice data.

**Fail-safe behavior:** None — the phone is blank.

**Recovery procedure:**
1. Build and install Alice on the new iPhone.
2. Pair with Hermes (QR or manual).
3. Conversations are lost unless encrypted sync was enabled. If sync was on,
   log into the Alice web account and pull conversations.
4. Re-grant Health, Calendar, and notification permissions.

**Recovery dependencies:** Hermes still running, Apple developer account.

**Preventive measure:** Enable encrypted sync in the web companion for
conversation backup.

### C. Local development environment becomes corrupted

**Impact:** Build failures, test failures, unpredictable behavior.

**Data at risk:** Source code (recoverable from git), local databases.

**Detection:** `npm run check:static` or `bash scripts/verify-ios.sh` fails.

**Fail-safe behavior:** CI catches issues before they reach production.

**Recovery procedure:**
1. `git clean -xfd` to remove untracked files.
2. `npm ci` to reinstall dependencies from lockfile.
3. Delete `ios/.build/` and regenerate: `cd ios && xcodegen generate`.
4. Delete local PGLite database (it will be recreated on next startup).
5. If Hermes databases are corrupted, restore from backup.

**Recovery dependencies:** Clean git checkout, npm lockfile.

**Preventive measure:** Pin exact dependency versions (already done via
`package-lock.json`). Use `npm ci` not `npm install`.

### D. GitHub is temporarily unavailable

**Impact:** Cannot push, pull, or run CI.

**Data at risk:** None — local copies are intact.

**Detection:** `git push` or `git pull` fails.

**Fail-safe behavior:** All local work continues. CI doesn't run but local
checks (`scripts/ci-local.sh`) are available.

**Recovery procedure:** Wait for GitHub to recover. Push when available.

**Recovery dependencies:** None.

**Preventive measure:** Local CI (`scripts/ci-local.sh`) exists as a fallback.
The pre-push hook runs the same checks.

### E. Hermes stops working

**Impact:** Alice cannot chat, run errands, or use any agent features.

**Data at risk:** None — Hermes data is on the Mac.

**Detection:** Health check shows gateway or dashboard failure. iPhone shows
"Hermes unreachable."

**Fail-safe behavior:** Alice shows a clear error. Existing conversations
remain on the phone.

**Recovery procedure:**
1. Check if Hermes process is running: `launchctl print gui/$(id -u)/ai.hermes.gateway`.
2. Restart: `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway`.
3. If that fails, check logs: `~/.hermes/logs/`.
4. If the model provider key is invalid, update it in the profile's `.env`.
5. If Hermes itself needs updating: `hermes update`.

**Recovery dependencies:** Hermes installation, model provider key.

**Preventive measure:** Health check monitors gateway availability. Notifier
can alert on failures.

### F. A critical dependency disappears

**Impact:** Depends on which dependency.

| Dependency          | If it disappears                         | Replacement difficulty |
| ------------------- | ---------------------------------------- | ---------------------- |
| Hermes (NousResearch) | Complete loss of agent capability       | Hard (fork or alternative agent) |
| Model provider     | No model responses                       | Easy (configure new provider) |
| Vercel              | Web companion down                       | Medium (self-host)     |
| Neon                | Database down                            | Medium (PGLite fallback works for dev) |
| Tailscale           | Cannot reach Hermes remotely             | Medium (use LAN or other VPN) |
| pypdf               | PDF form filling breaks                  | Low (alternative library) |
| Better Auth         | Web auth breaks                          | Medium (replace auth)  |
| TanStack Start      | Web framework disappears                 | Hard (rewrite web)     |

**Recovery dependencies:** Varies.

**Preventive measure:** See [DEPENDENCY_RISK](DEPENDENCY_RISK.md) for the full
audit and recommended seams.

### G. Credentials are revoked/rotated

**Impact:** Connection fails.

**Data at risk:** None.

**Detection:** Auth errors, 401/403 responses.

**Fail-safe behavior:** Alice shows "The key is not correct."

**Recovery procedure:**
1. **Gateway key:** Update in profile `.env` (`API_SERVER_KEY`). Re-pair iPhone
   or update manually in Connect settings.
2. **Dashboard credentials:** Update in Hermes config. Re-pair iPhone.
3. **Model provider key:** Update in profile `.env`.
4. **Vercel/Neon:** Rotate in respective dashboards. Update env vars.
5. **Bark key:** `security add-generic-password -U -s alice-bark -a "$USER" -w`.

**Recovery dependencies:** Access to Hermes config, provider dashboards.

**Preventive measure:** Document credential locations (see
[OPERATIONS](OPERATIONS.md)).

### H. An API provider shuts down

**Impact:** Model or external service unavailable.

**Data at risk:** None.

**Detection:** API errors, empty responses.

**Fail-safe behavior:** Alice shows errors. Fallback providers may be
configured per profile (`fallback_providers`).

**Recovery procedure:** Configure a new model provider in Hermes profile
settings. Update fallback chain.

**Recovery dependencies:** Alternative provider account.

**Preventive measure:** Use Hermes' `fallback_providers` feature. The Alice
plugin allows setting both primary and fallback from the agent page.

### I. Local persistent data is corrupted

**Impact:** Depends on which data store.

| Data store              | Corruption impact            | Recovery                           |
| ----------------------- | ---------------------------- | ---------------------------------- |
| Hermes SQLite databases | Lost sessions, memory, vault  | Restore from backup                 |
| iOS Keychain            | Lost credentials              | Re-pair                             |
| iOS UserDefaults        | Lost conversations, settings  | Irrecoverable without sync          |
| PGLite (web dev)        | Lost dev data                 | Delete and recreate                 |
| Neon database           | Lost web accounts, sync       | Restore from Neon backup            |

**Detection:** Read errors, malformed data, crashes.

**Fail-safe behavior:** Alice retains unreadable bytes for recovery rather
than overwriting with empty data (per AGENTS.md contract).

**Recovery procedure:** Restore from backup. For iOS, re-pair. For web,
re-run migrations.

**Preventive measure:** Regular backups via `scripts/backup-alice.sh`.
Encrypted sync for conversation preservation.

### J. A bad migration ships

**Impact:** Database schema incompatibility.

**Data at risk:** All database data.

**Detection:** Migration errors, query failures.

**Fail-safe behavior:** Migrations run in transactions (see `scripts/migrate.mjs`).
A failed migration is rolled back. The `_migrations` table tracks applied state.

**Recovery procedure:**
1. The migration is wrapped in a transaction — it either fully applied or
   was rolled back.
2. If partially applied (shouldn't happen due to transaction), restore from
   database backup.
3. Fix the migration, re-run `npm run db:migrate`.

**Recovery dependencies:** Database backup.

**Preventive measure:** Migrations are additive and backward-compatible (per
`docs/release-operations.md`). Never edit an applied migration. See
[MIGRATIONS](MIGRATIONS.md) for the full policy.

### K. An AI coding agent makes destructive changes

**Impact:** Corrupted source, broken builds, data loss.

**Data at risk:** Source code, potentially databases if migrations are bad.

**Detection:** CI failures, test failures, `git diff` review.

**Fail-safe behavior:**
- Pre-push hook runs Quality checks.
- `AGENTS.md` defines contracts that agents must follow.
- Secrets scan (gitleaks) runs on every push.

**Recovery procedure:**
1. `git revert` the bad commit(s).
2. If database changes shipped, see [MIGRATIONS](MIGRATIONS.md) for rollback.
3. Force-push the revert if needed (main is protected by CI).

**Recovery dependencies:** Git history.

**Preventive measure:** Never merge without CI passing. Review all diffs.
The `AGENTS.md` checklist requires evidence of correctness.

### L. Mac and iPhone run incompatible Alice versions

**Impact:** Protocol mismatch, silent failures.

**Data at risk:** Potentially conversations if Codable changes are
incompatible.

**Detection:** Unknown events, parsing errors, "Hermes sent something Alice
could not read."

**Fail-safe behavior:** Alice preserves unknown events safely. Codable
migrations read old archives before extending. Unreadable bytes are retained.

**Recovery procedure:**
1. Update the older side to match.
2. If conversation archives are unreadable, they are retained for manual
   recovery (not overwritten).

**Recovery dependencies:** Latest Alice source, Xcode.

**Preventive measure:** See [PROTOCOL](PROTOCOL.md) for version compatibility
rules. Codable must be backward-compatible.

### M. A partial deployment occurs

**Impact:** Web companion at wrong version, database at wrong schema.

**Data at risk:** Potentially web accounts, sync data.

**Detection:** Version mismatch between `X-Alice-Version` header and response
body. Release verifier catches this.

**Fail-safe behavior:** Vercel deployments are immutable. A partial deploy
means the production alias still points at the old deployment.

**Recovery procedure:**
1. Run `npm run release:verify -- <url>` to check.
2. If failed, promote the last known-good deployment in Vercel.
3. Do not rebuild — promote the immutable deployment.

**Recovery dependencies:** Vercel access.

**Preventive measure:** Release verification (`scripts/verify-release.mjs`).
Immutable deployments. See [release-operations](release-operations.md).

### N. Alice receives no maintenance for six months

**Impact:** Dependency drift, potential Hermes incompatibility, stale
fixtures.

**Data at risk:** None directly.

**Detection:** `npm audit` finds vulnerabilities. Hermes version no longer in
the compatibility matrix. CI may fail due to runner changes.

**Fail-safe behavior:** Existing functionality continues to work as long as
Hermes and dependencies don't change.

**Recovery procedure:**
1. `npm audit` and update vulnerable dependencies.
2. Check Hermes release notes for breaking changes.
3. Update contract fixtures if needed.
4. Run full verification suite.
5. Test on physical iPhone.

**Recovery dependencies:** Current Xcode, Node.js, Hermes.

**Preventive measure:** Pin dependency versions. Document upgrade paths.

## Backup procedure

### Automated backup script

```bash
# Run from the Mac that hosts Hermes.
bash scripts/backup-alice.sh
```

This creates a timestamped tarball of:
- `~/.hermes/` (profiles, sessions, memory, vault, config)
- `~/.hermes/plugins/alice/` (plugin code)
- Alice repo working directory (git-tracked changes)

Backups are stored in `~/.hermes/backups/`.

### What to back up

| What                          | Where                          | Frequency    |
| ----------------------------- | ------------------------------ | ------------ |
| Hermes databases              | `~/.hermes/`                   | Daily        |
| Alice plugin                  | `~/.hermes/plugins/alice/`     | On deploy    |
| Alice repo (uncommitted)       | Repo working directory         | On change    |
| iOS Keychain                   | iPhone (not directly backupable)| Via sync     |
| Neon database                 | Neon dashboard (automated)     | Automatic    |
| Vercel env vars               | Vercel dashboard               | On change    |

### What is NOT backed up

- iOS Keychain credentials (re-pair if lost)
- iOS UserDefaults conversations (use encrypted sync for preservation)
- Model provider keys (stored in Hermes profile `.env`, included in backup)
- Bark key (stored in macOS Keychain, must be re-added manually)
