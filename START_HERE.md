# START HERE

Read this first, in any coding tool, before touching Alice. It tells you
what Alice is, how it is built, and how to make a safe change. It links to
deeper documentation instead of duplicating it.

**Base commit:** `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 October 2026)

---

## 1. What Alice is

Alice is a native iPhone app for your own [Hermes](https://hermes-agent.nousresearch.com)
agent. You talk to it, watch it work and let it run errands for you. Hermes
and your model keys stay on your own Mac or server. Alice is a personal
project by Marc Freixanet, not on the App Store, built with Xcode.

Read: [README.md](README.md)

## 2. Repository structure

```
ios/                 SwiftUI app (iOS 26) — the primary product
  Alice/             App, design system, features, models, networking, storage
  AliceTests/        Unit tests
  AliceUITests/      UI tests
  AlicePerformance/  Performance measurements
  AliceActivities/   Live activities
  AliceShare/        Share extension
  project.yml        XcodeGen spec (generates Alice.xcodeproj)
  scripts/           Build and verification scripts
hermes-plugin/       Python plugin for Hermes (pairing, memory, feed, cards)
  tests/             Plugin tests
hermes-agents/       Alice's persona, routines and evals (Python + Markdown)
mac/notifier/        Optional macOS notifications
src/                 React 19 web companion (TanStack Start, TypeScript)
migrations/          SQL migrations (Neon Postgres / PGLite)
docs/                Architecture, verification, contracts, compatibility
```

Tool-specific instruction files:
- [AGENTS.md](AGENTS.md) — shared instructions for all coding tools (Codex, Claude Code, Cursor, etc.)
- [CLAUDE.md](CLAUDE.md) — points to AGENTS.md
- [.cursor/rules/alice.mdc](.cursor/rules/alice.mdc) — Cursor rules

## 3. What to read first

1. This file.
2. [AGENTS.md](AGENTS.md) — contracts, verification, task checklist.
3. [docs/architecture.md](docs/architecture.md) — system structure.
4. [SECURITY.md](SECURITY.md) — threat model, where secrets live.
5. [docs/verification.md](docs/verification.md) — how to check a change.
6. [docs/compatibility-matrix.md](docs/compatibility-matrix.md) — what works, what doesn't.

## 4. Architecture

| Surface | Stack | Responsibility |
| ------- | ----- | -------------- |
| iOS (primary) | SwiftUI, iOS 26, Keychain, HealthKit | Native conversations, agent work, configuration |
| Hermes plugin | Python, Hermes plugin API | Pairing, memory, briefings, cards, health, places, safety hooks |
| Web (companion) | React 19, TanStack Start, TypeScript | Browser access, account boundaries, encrypted sync |
| Mac notifier | Python, macOS | Optional local notifications |

Key architectural decisions:
- **Official Hermes, no fork.** Everything Alice needs from the server lives in a Hermes plugin. Updating Hermes does not overwrite Alice.
- **The phone never becomes the server.** No push infrastructure, no cloud of our own. The iPhone talks to Hermes over the network.
- **Hermes' safety stays in charge.** Cards and logins go into Hermes' vault. Payments pass Hermes' confirmation. Alice adds checks on top, never removes any.
- **Deterministic where it can be.** Health patterns use statistics, not the model. Card formats use the Luhn algorithm.

Read: [docs/architecture.md](docs/architecture.md)

## 5. Sources of truth

| What | Where |
| ---- | ----- |
| Engineering rules | [AGENTS.md](AGENTS.md) |
| Architecture | [docs/architecture.md](docs/architecture.md) |
| Hermes contracts | [docs/hermes-contracts.md](docs/hermes-contracts.md) |
| Compatibility | [docs/compatibility-matrix.md](docs/compatibility-matrix.md) |
| Verification | [docs/verification.md](docs/verification.md) |
| Security | [SECURITY.md](SECURITY.md) |
| Release operations | [docs/release-operations.md](docs/release-operations.md) |
| Pairing protocol | [docs/pairing.md](docs/pairing.md) |
| Purchases | [docs/purchases.md](docs/purchases.md) |
| Persistence/migrations | [docs/MIGRATIONS.md](docs/MIGRATIONS.md) |
| Data integrity | [docs/DATA_INTEGRITY.md](docs/DATA_INTEGRITY.md) |
| Observability | [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) |
| Diagnostic bundle | [docs/DIAGNOSTIC_BUNDLE.md](docs/DIAGNOSTIC_BUNDLE.md) |
| SPOF audit | [docs/SINGLE_POINTS_OF_FAILURE.md](docs/SINGLE_POINTS_OF_FAILURE.md) |
| Architectural decisions | [docs/adr/](docs/adr/) |

## 6. Engineering rules

From [AGENTS.md](AGENTS.md) — read it in full. Key contracts:

- **Connection identity:** home chat belongs to the installation's main profile. Bot chats carry their own profile and canonical session. Never silently reroute a conversation.
- **Credentials:** validate origins before attaching secrets. Keep iOS secrets in Keychain. Never log or commit secrets.
- **Data:** read old Codable archives before extending persisted models. A Swift property default does not make synthesized decoding backward-compatible. Never replace an unreadable archive with an empty one.
- **Synchronization:** validate a recovery key before replacing the saved key. Save pulled records and their cursor together.
- **Hermes:** use official, versioned source contracts. Preserve unknown stream events safely.
- **User experience:** iOS first. Destructive actions must clearly name their target. Never claim completion before the remote operation succeeds.
- **Notifications:** distinguish an agent answer, routine delivery, failure and approval. iOS background execution is opportunistic.

## 7. How to set up

### iOS app

```bash
brew install xcodegen
cd ios && xcodegen generate
open Alice.xcodeproj
```

In Xcode, choose your team under Signing, select your iPhone and press Run.

### Hermes plugin

```bash
git clone https://github.com/Freixanet/alice.git
cd alice
hermes-plugin/install.sh
```

### Web companion

```bash
npm ci
npm run dev
```

Read: [README.md](README.md) (Get started), [docs/getting-connected.md](docs/getting-connected.md)

## 8. How to build

### iOS (device build)

```bash
xcodebuild -project ios/Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE_ID> \
  ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
```

### iOS (simulator, CI only — not on the dev Mac)

```bash
bash scripts/verify-ios.sh all
```

Read: [docs/verification.md](docs/verification.md)

## 9. How to test

| Suite | Command | Notes |
| ----- | ------- | ----- |
| iOS unit + UI | `bash scripts/verify-ios.sh all` | CI only; dev Mac has no simulator |
| Web static | `npm run check:static` | Types, lint |
| Web e2e | `npm run test:e2e` | Playwright, isolated DB |
| Plugin | `python -m unittest discover -s hermes-plugin/tests` | Needs Hermes virtualenv |
| Notifier | `python -m unittest discover -s mac/notifier` | |
| Secret scan | `gitleaks detect --source=. --no-banner --redact` | |

The dev Mac (Intel, 16 GB) has no iOS simulator, on purpose. Do not create
simulators or download simulator runtimes. A successful device build is the
local iOS check. Report that simulator tests were not run.

## 10. How to choose validation scope

- Changed Swift code → `bash scripts/verify-ios.sh unit` (if a simulator is available) or device build.
- Changed UI → also `bash scripts/verify-ios.sh ui` and visual review.
- Changed web code → `npm run check:static` and `npm run test:e2e`.
- Changed plugin → `python -m unittest discover -s hermes-plugin/tests`.
- Changed persistence or models → run the migration tests: `ConversationMigrationTests`, `ConversationPersistenceTests`, `ForwardCompatibilityTests`.
- Changed Hermes contracts → update fixtures, run live contract check.
- Cross-surface change → check both transports, profile scoping, `npm run slash:check`.
- Regenerate `ios/Alice.xcodeproj` from `ios/project.yml` if project structure changed. Never commit the generated project.

## 11. How to diagnose

- **iOS:** Developer screen → Checks, Performance meter, Recent activity (from `DiagnosticsLog`).
- **iOS:** `/debug` chat command posts diagnostics to Hermes.
- **iOS:** `devicectl --domain-type appDataContainer` to copy off diagnostics.log.
- **Web:** `X-Alice-Version` header, `alice_operational` and `alice_alert` log records.
- **Hermes:** `~/.hermes/logs/gateway.log` and `~/.hermes/logs/dashboard.log`.

Read: [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md), [docs/DIAGNOSTIC_BUNDLE.md](docs/DIAGNOSTIC_BUNDLE.md)

## 12. How to make a safe change

1. Read this file, AGENTS.md and the relevant docs.
2. Check `git status --short`, the branch and the base commit. Preserve existing changes.
3. Identify the affected surface and its tests. Work on a topic branch.
4. Make the smallest coherent change. Avoid unrelated formatting and speculative rewrites.
5. Cover the whole path: input → action → result → persistence, including empty, loading, error and recovery states.
6. Protect data and actions: validate input, check permissions, never expose secrets. Consider double submission, concurrency and network failure.
7. Care for the real interface: reuse components, check hierarchy, copy, layout, keyboard, focus, contrast.
8. Run the checks that apply (tests, types, lint, build).
9. Review the whole diff: accidental changes, secrets, incompatibilities, documentation left wrong.
10. Report precisely: what changed, what was checked, what could not be checked, what risk remains.

From [AGENTS.md](AGENTS.md) — read the full task checklist.

## 13. What not to change casually

- **ConversationArchive and ConversationStorage** — the write order, salvage path and migration logic are the data integrity guarantee. Any change needs regression coverage.
- **KeyStore** — the update-then-add pattern is deliberate. Delete-then-add can lose the credential.
- **Codable models (Chat.swift, Message, Conversation)** — adding a non-optional property without a decoder default will break every existing archive. See [docs/MIGRATIONS.md](docs/MIGRATIONS.md).
- **SQL migrations** — applied migrations are immutable. Add new ones, never edit existing ones.
- **Hermes contract fixtures** — pinned to specific Hermes commits. Update only after reading the release notes and checking changed source contracts.
- **AppStore.swift** — already a large coordinator. New behavior should go in focused modules, not here.
- **Hermes safety hooks** — Alice adds checks on top of Hermes' safety. Never remove or weaken Hermes' own checks.
- **Pairing protocol** — the QR exchange is a security boundary. See [docs/pairing.md](docs/pairing.md).
- **The .env files** — secret_store.py writes to these. Never commit them.

## 14. How iPhone/Mac/Hermes boundaries work

```
iPhone (Alice app)
  ├── Keychain: Hermes key (ThisDeviceOnly)
  ├── File storage: conversations, drafts, feed, launch cache
  ├── UserDefaults: settings, bot layout, activity
  └── Network: HTTPS/WebSocket to Hermes gateway + dashboard

Mac (Hermes runtime)
  ├── Gateway (ai.hermes.gateway): agent API, chat, tools
  ├── Dashboard (ai.hermes.dashboard): management, profiles, Alice plugin
  ├── Alice plugin: pairing, memory, feed, cards, health, places
  ├── Browser: shared Chromium for live view
  └── .env: API keys, model provider credentials

Web (companion, optional)
  ├── Vercel deployment: account auth, encrypted sync proxy
  ├── Neon Postgres: auth, sync records, rate limits
  └── Browser: direct mode or server proxy to Hermes
```

The iPhone talks directly to the Mac's Hermes over the network (same LAN or
Tailscale). The web companion is a separate surface with its own account
system. Encrypted conversation sync is web-only; iOS does not share that
implementation.

Read: [docs/architecture.md](docs/architecture.md), [docs/pairing.md](docs/pairing.md), [docs/hermes-contracts.md](docs/hermes-contracts.md)

## 15. How to recover from failure

- **App won't launch:** Check diagnostics.log. If a conversation archive is corrupt, the salvage path retains the bytes. The app starts with an empty list.
- **Cannot connect to Hermes:** Check DiagnosticChecks. Verify Hermes is running, the address is correct, and the network is reachable. Re-pair if the key was lost.
- **Bad code on main:** `git revert` the commit. CI runs on every push to main. The last known-good build is on the iPhone.
- **Bad migration shipped:** SQL migrations are additive; a code rollback should work. If a Codable change broke decoding, the standing tests catch it before it ships. If it shipped anyway, the salvage path retains the bytes.
- **Hermes plugin broken:** Back up `~/.hermes/plugins/alice` to `~/.hermes/backups/`, then reinstall from the repo. Restart gateway, then dashboard, one at a time.
- **Web deployment broken:** Select the last known-good immutable Vercel deployment and promote it. Run the release verifier. See [docs/release-operations.md](docs/release-operations.md).

Read: [docs/DATA_INTEGRITY.md](docs/DATA_INTEGRITY.md), [docs/release-operations.md](docs/release-operations.md), [docs/SINGLE_POINTS_OF_FAILURE.md](docs/SINGLE_POINTS_OF_FAILURE.md)

---

This file is the entry point. The repository itself is Alice's long-term
engineering memory. Do not depend on proprietary prompt memory or AI
conversation context that may not persist.
