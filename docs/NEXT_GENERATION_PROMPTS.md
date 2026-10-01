# Next-generation Perplexity Computer prompts for Alice

This document designs the best possible set of additional Perplexity Computer
tasks/prompts for the Alice project. It is based on a deep inspection of the
repository at `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 October 2026).

**Principle:** "Spend expensive autonomous intelligence once to permanently
reduce how much intelligence future maintenance requires."

---

## Assessment of existing antifragility prompts (Tasks 15-21)

| Task | Assessment |
| ---- | ---------- |
| 15. Persistence/migrations | **Well-scoped.** The audit found existing protections are already strong. The docs + forward-compatibility test are the right output. |
| 16. Observability | **Well-scoped.** Documentation-only is appropriate. The existing diagnostics are sufficient for a personal project. |
| 17. SPOF | **Well-scoped.** The "no redundancy just because" principle is correct for a personal project. |
| 18. START_HERE | **Essential.** The highest-leverage documentation. No changes needed to the prompt. |
| 19. ADRs | **Well-scoped.** The "no fabricated rationale" principle is correct. 9 ADRs is the right number — not every technical choice needs one. |
| 20. Antifragility audit | **Well-scoped** but should explicitly note it depends on merged PRs. The instruction to re-run after merging is correct. |
| 21. Meta-prompt | **This task.** |

**No existing prompt is weak, redundant or incorrectly scoped.** Each
addresses a distinct failure class and the output is appropriate to Alice's
scale.

---

## Repository evidence

| Metric | Value |
| ------ | ----- |
| Commits | 287 |
| Fix commits | 132 (46% of all commits) |
| Swift files | 379 |
| TypeScript files | 181 |
| Python files | 86 |
| Markdown docs | 57 |
| SQL migrations | 5 |
| iOS tests | ~200 (in AliceTests/) |
| Plugin tests | ~35 (in hermes-plugin/tests/) |
| TODO/FIXME/HACK markers | 0 (clean) |
| CI workflows | 3 (quality, browser, ios) |

The 132 fix commits represent real-world failures that were found and
addressed. The commit messages are descriptive (e.g., "fix: the chat reads
in order", "fix: a purchase looks before it asks"). These failures are
Alice's most valuable learning resource, and they are not yet extracted
into a permanent document.

---

## Proposed prompts

### EXECUTE WHILE COMPUTER IS FREE — CRITICAL

---

#### Prompt A: Extract failure learnings from Git history

**TITLE:** Alice — Extract and codify failure learnings from Git history

**WHY THIS IS HIGH LEVERAGE FOR ALICE SPECIFICALLY:** Alice has 132 fix
commits (46% of all commits). Each represents a real-world failure that was
found, diagnosed and fixed. The commit messages are descriptive and the
diffs are in the repository. But this knowledge exists only in Git history —
a future engineer or agent would have to read 132 commits to learn what can
go wrong. Extracting these into a structured document creates a permanent
failure-mode catalog that future maintenance can reference.

**WHAT EVIDENCE IN THE CURRENT REPO MOTIVATED IT:** 132 fix commits with
descriptive messages. No `docs/FAILURE_LEARNINGS.md` exists. The
`ConversationMigrationTests` comment ("the regression that erased the
phone") shows that the most important learnings are already being preserved
as standing tests — but only for the ones that were catastrophic. The
132 commits include purchase flow fixes, chat ordering fixes, plugin
crash recovery, background execution, and more.

**EXPECTED DURABLE OUTPUT:** `docs/FAILURE_LEARNINGS.md` — a structured
catalog of failure modes discovered through development, organized by
subsystem (chat, purchases, plugin, iOS lifecycle, Hermes, sync, etc.).
Each entry: what failed, how it was detected, how it was fixed, and the
test that guards against recurrence. No user data.

**SHOULD:** CREATE DOCUMENTATION

**RISK LEVEL:** Low (documentation-only)

**RECOMMENDED EXECUTION ORDER:** 1 (after Tasks 15-20 PRs are merged)

**DEPENDENCIES ON OTHER PROMPTS:** Benefits from START_HERE.md (PR #47)
and ADRs (PR #53) for context.

**THE COMPLETE COPY-PASTE EMAIL PROMPT:**

---

Subject: Alice — Extract failure learnings from Git history

Repository: Freixanet/alice
URL: https://github.com/Freixanet/alice
Branch to inspect: latest main
Application: Alice
iOS project: ios/Alice.xcodeproj
Bundle identifier: com.freixanet.alice

Start by inspecting the LATEST state of main and record its exact HEAD commit
SHA.

Alice has 132 fix commits — 46% of its 287 total commits. Each represents a
real-world failure that was found, diagnosed and fixed. The commit messages
are descriptive (e.g., "fix: the chat reads in order, the product sheet fits,
and the agent fixes its own basket"). This knowledge exists only in Git
history.

Extract these failures into a permanent, structured catalog.

Read every fix commit. For each, extract:
1. WHAT failed (the user-visible symptom)
2. WHICH subsystem was affected
3. HOW it was detected
4. HOW it was fixed
5. WHAT test guards against recurrence (if any)
6. WHETHER the failure could recur in a different form

Organize by subsystem:
- Chat and streaming
- Purchases and errands
- Plugin (memory, feed, browser, secrets, egress)
- iOS lifecycle (background, foreground, dictation, voice)
- Hermes connectivity (gateway, dashboard, pairing)
- Persistence (conversations, drafts, settings)
- Routines and proactive
- Notifications and approvals
- Model and provider
- CI and build

Create `docs/FAILURE_LEARNINGS.md`.

Do not include user data, credentials or conversation content. Do not
include fix commits for security patches (brace-expansion, undici) — those
are dependency updates, not Alice failures.

Documentation-only. Dedicated branch, draft PR, never merge automatically.

---

#### Prompt B: Architectural contract tests

**TITLE:** Alice — Automated architectural contract tests

**WHY THIS IS HIGH LEVERAGE FOR ALICE SPECIFICALLY:** AGENTS.md defines
contracts that "must survive changes": connection identity (home chat =
main profile, bot chats = own profile, never silently reroute),
credentials (validate origins, Keychain only, never log), data (read old
archives, never replace unreadable with empty), synchronization (validate
recovery key, save cursor with state). These contracts are currently
enforced only by code review. A future AI agent could violate one and CI
would not catch it. Automated tests that verify these contracts turn
human-enforced rules into machine-enforced rules.

**WHAT EVIDENCE IN THE CURRENT REPO MOTIVATED IT:** AGENTS.md's "Contracts
that must survive changes" section. The `ConversationMigrationTests` are
the only architectural contract tests that exist — they guard the specific
regression that erased conversations. But the connection identity contract
(home chat = main profile), the credential contract (Keychain only), and
the synchronization contract (validate recovery key) have no automated
tests. The antifragility audit (Scenario 20) identified this as PARTIAL.

**EXPECTED DURABLE OUTPUT:** New test files in `ios/AliceTests/` that verify:
- Home conversation always uses the main profile
- Bot chats carry their own profile and session
- Conversations are never silently rerouted
- KeyStore never writes to UserDefaults
- ConversationArchive never replaces unreadable bytes with empty
- Drafts are saved per-conversation, not globally
- A failed write is reported, not silently swallowed

**SHOULD:** CREATE TESTS

**RISK LEVEL:** Low (tests only, no production code changes)

**RECOMMENDED EXECUTION ORDER:** 2 (after Prompt A and Tasks 15-20 PRs)

**DEPENDENCIES ON OTHER PROMPTS:** Benefits from ADRs (PR #53) for the
contract definitions.

**THE COMPLETE COPY-PASTE EMAIL PROMPT:**

---

Subject: Alice — Automated architectural contract tests

Repository: Freixanet/alice
URL: https://github.com/Freixanet/alice
Branch to inspect: latest main
Application: Alice
iOS project: ios/Alice.xcodeproj
Bundle identifier: com.freixanet.alice

Start by inspecting the LATEST state of main and record its exact HEAD commit
SHA.

AGENTS.md defines "Contracts that must survive changes." These contracts
are currently enforced only by code review. Turn them into automated tests
so CI catches violations.

Create tests in `ios/AliceTests/` that verify:

1. Connection identity:
   - Home conversation always uses the main installation profile
   - Bot chats carry their own profile and canonical session
   - Switching conversations does not reroute an in-flight turn
   - An @agent reply retains its own profile and session

2. Credentials:
   - KeyStore never writes the Hermes key to UserDefaults
   - KeyStore uses update-then-add, never delete-then-add
   - DiagnosticsLog never writes message content

3. Data:
   - ConversationArchive never replaces unreadable bytes with an empty
     archive
   - An archive with unknown fields decodes without throwing
   - A failed write is reported (FileConversationStorage.takeFailure)

4. Synchronization:
   - The pull cursor is saved with the corresponding state
   - An account change cancels pending work from the old account

Use fixture data, not real conversations. Do not send prompts to or change
settings on a live Hermes.

Dedicated branch, draft PR, never merge automatically. Avoid unrelated
changes.

---

### EXECUTE WHILE COMPUTER IS FREE — HIGH VALUE

---

#### Prompt C: Schema version on conversation records

**TITLE:** Alice — Add schema version to conversation records

**WHY THIS IS HIGH LEVERAGE FOR ALICE SPECIFICALLY:** The antifragility audit
(Scenario 11) identified the lack of a schema version on conversation
records as a PARTIAL risk. The current approach (optional Codable fields)
only supports additive changes. A schema version would enable explicit
migration logic for breaking changes and detect downgrade incompatibility.
This is a small code change with a large payoff: it is the prerequisite for
any future breaking schema change.

**WHAT EVIDENCE IN THE CURRENT REPO MOTIVATED IT:**
`ConversationArchive.swift` has no version field. The `ForwardCompatibilityTests`
(PR #41) document that a load → re-save cycle through an older build strips
unknown fields. The `docs/MIGRATIONS.md` (PR #41) recommends a schema version
as the first improvement. The `cloud-sync-runtime.ts` already has `version: 1`
on sync state objects — the iOS app does not follow this pattern.

**EXPECTED DURABLE OUTPUT:**
- Add `version: Int = 1` to the conversation archive format (optional, so
  old archives decode)
- On load, if `version` is absent, treat as version 0 (the current format)
- On load, if `version` is higher than the build knows, do not save (prevent
  downgrade data loss)
- A test that loads a version-0 archive and verifies it saves as version 1
- A test that loads a version-2 archive (future) and verifies the build
  refuses to save

**SHOULD:** IMPLEMENT PROTECTIONS, CREATE TESTS

**RISK LEVEL:** Medium (touches the conversation model and archive format;
must be backward-compatible)

**RECOMMENDED EXECUTION ORDER:** 3 (after Prompt B)

**DEPENDENCIES ON OTHER PROMPTS:** Prompt B (architectural contract tests
should exist first to verify the version field does not break existing
contracts)

**THE COMPLETE COPY-PASTE EMAIL PROMPT:**

---

Subject: Alice — Add schema version to conversation records

Repository: Freixanet/alice
URL: https://github.com/Freixanet/alice
Branch to inspect: latest main
Application: Alice
iOS project: ios/Alice.xcodeproj
Bundle identifier: com.freixanet.alice

Start by inspecting the LATEST state of main and record its exact HEAD commit
SHA.

Add a schema version to the conversation archive format. This is the
prerequisite for any future breaking schema change and prevents downgrade
data loss.

Requirements:
1. Add `version: Int? = nil` to the conversation JSON (optional, so old
   archives without a version key decode as before).
2. On load, if `version` is absent, treat as version 0 (the current format).
3. On load, if `version` is present and higher than the build knows (1),
   do not save — show a warning instead. This prevents an older build from
   silently stripping fields it does not understand.
4. On save, write `version: 1` into the conversation JSON.
5. The blob→split migration and the UserDefaults→file migration must
   preserve the version field.

Tests:
- A version-0 archive (no version key) loads and saves as version 1.
- A version-1 archive loads correctly.
- A version-2 archive (simulated future) loads for reading but the build
  refuses to save (to prevent downgrade data loss).

Do not change the `Conversation` or `Message` model structs. The version
is a property of the archive, not the model. Add it to the archive's
`Record` or `PreparedWrite`.

Dedicated branch, draft PR, never merge automatically. Avoid unrelated
changes.

---

#### Prompt D: Plugin state recovery audit

**TITLE:** Alice — Audit Hermes plugin state recovery

**WHY THIS IS HIGH LEVERAGE FOR ALICE SPECIFICALLY:** The Hermes plugin
has multiple state files: `entries.json`, `changes.json`, `settings.json`
(memory_keeper), `.env` files (secret_store), and Hermes' own `MEMORY.md`
and `USER.md`. Each file has a failure mode: corruption, partial write,
accidental deletion, hand editing. The memory_keeper has atomic writes and
a revert capability, but there is no audit of what happens when each file
is individually corrupted. Computer can systematically corrupt each file
and document the outcome.

**WHAT EVIDENCE IN THE CURRENT REPO MOTIVATED IT:**
`memory_keeper.py` uses `_read(name, default)` which returns the default
on any error. `secret_store.py` uses atomic writes. But neither has tests
for corruption recovery (the plugin tests test functionality, not failure
recovery). The `docs/DATA_INTEGRITY.md` (PR #41) notes: "No integrity
check on plugin memory."

**EXPECTED DURABLE OUTPUT:**
- `docs/PLUGIN_STATE_RECOVERY.md` — for each state file: what happens when
  it is corrupted, deleted, or hand-edited. What the person loses. How to
  recover.
- New tests in `hermes-plugin/tests/` that verify recovery from corrupted
  state files.

**SHOULD:** AUDIT ONLY, CREATE DOCUMENTATION, CREATE TESTS

**RISK LEVEL:** Low (documentation and tests only)

**RECOMMENDED EXECUTION ORDER:** 4

**DEPENDENCIES ON OTHER PROMPTS:** Benefits from `docs/MIGRATIONS.md` (PR
#41) for the plugin memory migration section.

**THE COMPLETE COPY-PASTE EMAIL PROMPT:**

---

Subject: Alice — Audit Hermes plugin state recovery

Repository: Freixanet/alice
URL: https://github.com/Freixanet/alice
Branch to inspect: latest main
Application: Alice
iOS project: ios/Alice.xcodeproj
Bundle identifier: com.freixanet.alice

Start by inspecting the LATEST state of main and record its exact HEAD commit
SHA.

The Hermes plugin has multiple state files. Audit what happens when each
is corrupted, partially written, deleted, or hand-edited.

State files:
- `~/.hermes/profiles/<profile>/.alice/memory/entries.json`
- `~/.hermes/profiles/<profile>/.alice/memory/changes.json`
- `~/.hermes/profiles/<profile>/.alice/memory/settings.json`
- `~/.hermes/profiles/<profile>/.alice/memory/declined.json`
- `~/.hermes/.env` (and per-profile `.env`)
- Hermes' own `memories/MEMORY.md` and `memories/USER.md`

For each file:
1. What happens when it is corrupted (invalid JSON)?
2. What happens when it is partially written?
3. What happens when it is deleted?
4. What happens when it is hand-edited with invalid structure?
5. What data is lost?
6. How does the plugin recover (or fail)?
7. How should the person recover?

Create `docs/PLUGIN_STATE_RECOVERY.md`.

Create tests in `hermes-plugin/tests/` that verify:
- A corrupted `entries.json` does not crash the plugin
- A corrupted `changes.json` does not prevent cleanup
- A deleted `settings.json` defaults to safe values (apply=false, learn=true)
- A corrupted `.env` does not crash `secret_store`

Use the Hermes virtualenv to run plugin tests. Do not test against the
person's real Hermes.

Dedicated branch, draft PR, never merge automatically.

---

#### Prompt E: Cross-surface state machine documentation

**TITLE:** Alice — Document cross-surface state machines

**WHY THIS IS HIGH LEVERAGE FOR ALICE SPECIFICALLY:** Alice has complex state
transitions across surfaces: a conversation can be streaming, pending,
failed, cancelled, interrupted, waiting for approval, or completed. An agent
task can be creating, created, running, paused, failed, or completed. A
routine can be scheduled, running, quiet, or failed. These states are
spread across `Chat.swift`, `AgentTaskSession.swift`, `HermesRunProtocol.swift`,
`RoutineCatalog.swift`, and the sync state in `cloud-sync-runtime.ts`.
Documenting them as state machines makes the valid transitions explicit
and catches impossible states.

**WHAT EVIDENCE IN THE CURRENT REPO MOTIVATED IT:**
`Message.RunStatus` has 8 states with `isTerminal`. `Message.Approval` has
`resolving`, `error`, `smartDenied`, `viaSocket` — all optional. The sync
state has 8 statuses. The routine quiet-run logic has `quietRoutineRuns`
and `judgedRoutineRuns`. These are all stateful, and the valid transitions
are implicit in the code.

**EXPECTED DURABLE OUTPUT:**
- `docs/STATE_MACHINES.md` — state diagrams (as text) for:
  - Conversation lifecycle (blank → active → streaming → completed/failed)
  - Message lifecycle (user → pending → streaming → completed/failed/cancelled)
  - Agent task lifecycle (draft → creating → created → running → completed/failed)
  - Approval lifecycle (requested → resolving → approved/denied)
  - Routine lifecycle (scheduled → running → quiet → reported/failed)
  - Sync lifecycle (idle → syncing → synced/offline/key-mismatch/error)
  - Errand lifecycle (requested → browsing → checkout → approved → paid/declined/failed)

**SHOULD:** CREATE DOCUMENTATION

**RISK LEVEL:** Low (documentation-only)

**RECOMMENDED EXECUTION ORDER:** 5

**DEPENDENCIES ON OTHER PROMPTS:** Benefits from ADRs (PR #53) for context.

**THE COMPLETE COPY-PASTE EMAIL PROMPT:**

---

Subject: Alice — Document cross-surface state machines

Repository: Freixanet/alice
URL: https://github.com/Freixanet/alice
Branch to inspect: latest main
Application: Alice
iOS project: ios/Alice.xcodeproj
Bundle identifier: com.freixanet.alice

Start by inspecting the LATEST state of main and record its exact HEAD commit
SHA.

Document the state machines that govern Alice's behavior. The valid
transitions are currently implicit in the code.

Create `docs/STATE_MACHINES.md` with text-based state diagrams for:

1. Conversation lifecycle (blank → active → streaming → completed/failed)
2. Message lifecycle (user → pending → streaming → completed/failed/cancelled/interrupted)
3. Agent task lifecycle (draft → creating → created → running → completed/failed)
4. Approval lifecycle (requested → resolving → approved/denied/smart-denied)
5. Routine lifecycle (scheduled → running → quiet → reported/failed)
6. Sync lifecycle (idle → syncing → synced/offline/key-mismatch/quota-exceeded/error)
7. Errand lifecycle (requested → browsing → checkout → approved → paid/declined/failed)
8. Bot chat lifecycle (canonical → read → recovered → local-only)

For each state machine:
- States (with their source: which struct/enum defines them)
- Valid transitions
- Invalid transitions (and what prevents them)
- Terminal states
- Recovery from non-terminal failure states

Do not change code. Documentation-only. Dedicated branch, draft PR.

---

### USE ONLY IF TIME/CAPACITY REMAINS

---

#### Prompt F: Hermes contract drift detector

**TITLE:** Alice — Build a Hermes contract drift detector

**WHY THIS IS HIGH LEVERAGE FOR ALICE SPECIFICALLY:** Hermes contract fixtures
are pinned to specific commits (`b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`).
Hermes releases new versions. Currently, detecting drift requires manually
comparing the fixtures against the new release. A script that fetches the
latest Hermes release, compares the contract surface, and reports changes
would automate this. But this is lower leverage because Hermes releases
infrequently and the comparison is a one-time-per-release task.

**WHAT EVIDENCE IN THE CURRENT REPO MOTIVATED IT:**
`docs/hermes-contracts.md` pins fixtures to `0.21.3`, `0.21.2`, `0.21.0`,
`0.20.6`. The CI installs Hermes at a specific commit. The fixtures are
in `src/lib/hermes-contract-fixtures.ts`.

**EXPECTED DURABLE OUTPUT:** A script (`scripts/check-hermes-drift.sh`)
that fetches the latest Hermes release tag, compares the HTTP endpoint
surface against the fixtures, and reports new/removed/changed endpoints.

**SHOULD:** MODIFY TOOLING

**RISK LEVEL:** Low (script only, no production code)

**RECOMMENDED EXECUTION ORDER:** 6

**DEPENDENCIES:** None

**THE COMPLETE COPY-PASTE EMAIL PROMPT:**

---

Subject: Alice — Build a Hermes contract drift detector

Repository: Freixanet/alice
URL: https://github.com/Freixanet/alice
Branch to inspect: latest main
Application: Alice
iOS project: ios/Alice.xcodeproj
Bundle identifier: com.freixanet.alice

Start by inspecting the LATEST state of main and record its exact HEAD commit
SHA.

Create a script that detects when Hermes has released a new version and
what contract surface changed.

The script should:
1. Fetch the latest Hermes release tag from GitHub.
2. Compare the HTTP endpoint surface against `src/lib/hermes-contract-fixtures.ts`.
3. Report: new endpoints, removed endpoints, changed methods.
4. Not fail the build — it is informational.

Place it in `scripts/check-hermes-drift.sh`.

Dedicated branch, draft PR, never merge automatically.

---

#### Prompt G: Web sync edge case audit

**TITLE:** Alice — Audit web sync edge cases

**WHY THIS IS HIGH LEVERAGE FOR ALICE SPECIFICALLY:** The encrypted sync
has many edge cases: key mismatch, account change mid-sync, partial upload,
partial download, quota exceeded, offline during sync. The sync code is
well-tested (`cloud-sync-runtime.test.ts`, `sync-crypto.test.ts`,
`sync-merge.test.ts`, `sync-replica.test.ts`, `sync-store.server.test.ts`)
but an adversarial audit of edge cases could find gaps.

**WHAT EVIDENCE IN THE CURRENT REPO MOTIVATED IT:** 8 sync-related test
files exist. The sync state has 8 statuses. The `cloud-sync-runtime.ts`
has defensive parsing. But the combination of failures (key mismatch +
offline, account change + partial download) may not be tested.

**EXPECTED DURABLE OUTPUT:** A report of edge cases, with tests for any
that are not covered.

**SHOULD:** AUDIT ONLY, CREATE TESTS

**RISK LEVEL:** Low

**RECOMMENDED EXECUTION ORDER:** 7

**DEPENDENCIES:** None

**THE COMPLETE COPY-PASTE EMAIL PROMPT:**

---

Subject: Alice — Audit web sync edge cases

Repository: Freixanet/alice
URL: https://github.com/Freixanet/alice
Branch to inspect: latest main
Application: Alice
iOS project: ios/Alice.xcodeproj
Bundle identifier: com.freixanet.alice

Start by inspecting the LATEST state of main and record its exact HEAD commit
SHA.

Audit the encrypted conversation sync for edge cases. The sync has 8 statuses
(idle, syncing, synced, pending, offline, key-mismatch, quota-exceeded,
error) and many failure combinations.

Audit:
1. Key mismatch during an active sync
2. Account change mid-sync
3. Partial upload (network drops mid-write)
4. Partial download (server returns partial data)
5. Quota exceeded during upload
6. Offline during sync (recover when online)
7. Concurrent sync attempts
8. Cursor saved but state not (or vice versa)
9. Tombstone for a conversation that was never synced
10. Sync state version mismatch (future version)

For each: what happens? Is it tested? If not, add a test.

Dedicated branch, draft PR, never merge automatically.

---

### NOT WORTH USING COMPUTER FOR

---

- **Trivial coding work** — Bug fixes, small UI changes, text edits. Any
  coding tool can do these.
- **Cosmetic refactoring** — Renaming variables, reformatting code, splitting
  files. These do not reduce future maintenance.
- **Generic best practices** — Adding lint rules, formatting checks, code
  coverage thresholds. These are standard and do not require Computer's
  deep analysis.
- **Feature brainstorming** — New features should come from the person's
  needs, not from an AI agent.
- **Dependency upgrades** — `npm audit` and `npm run deps:check` already
  exist in CI. Running them is a one-line command.
- **Enterprise infrastructure** — Datadog, Sentry, OpenTelemetry, APNs,
  push servers. Alice is a personal project; these add cost and complexity.

---

## PROMPTS I WOULD RUN IF I ONLY HAD 24 HOURS OF FREE COMPUTER LEFT

If Computer access ends tomorrow, the minimum set that would leave Alice
dramatically easier, cheaper and safer to maintain:

1. **Prompt A: Extract failure learnings from Git history** — The 132 fix
   commits are Alice's most valuable learning resource. Extracting them
   into a permanent document means any future engineer or agent can learn
   what can go wrong without reading 132 commits. This is the single
   highest-leverage use of Computer's ability to read and synthesize Git
   history.

2. **Prompt B: Architectural contract tests** — Turn AGENTS.md's contracts
   into automated tests. This is the difference between "a rule on paper"
   and "a rule CI enforces." It is the most durable code change Computer
   can make: once written, these tests guard against the most dangerous
   class of future regression (architectural violations by AI agents that
   do not understand the system).

3. **Prompt C: Schema version on conversation records** — A small code
   change that is the prerequisite for any future breaking schema change.
   Without it, a downgrade silently strips data. With it, the build can
   refuse to save. This is the kind of change that is easy to do now and
   painful to add later (every existing archive would need migration).

These three prompts are the minimum because:
- Prompt A captures the past (what has failed).
- Prompt B enforces the present (what must not break).
- Prompt C protects the future (what schema changes are safe).

Together, they reduce the intelligence required for future maintenance:
a future agent does not need to read 132 commits, does not need to
understand every contract to avoid violating them, and does not need to
worry about downgrade data loss.

The documentation PRs (Tasks 15-20) are the foundation. These three
prompts build on that foundation to create permanent, machine-enforced
protections.
