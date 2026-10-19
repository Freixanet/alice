# AI Agent Guide

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`
>
> This guide is the **strict, project-specific engineering guide** for every
> future AI coding agent that works on Alice. It is derived from Alice's
> actual architecture, recurring bugs, Git history, and current
> implementation. It is **not generic AI coding advice.**
>
> If you are an AI coding agent (Claude Code, Codex, Cursor, or any other),
> read this file before touching any code. Then read
> [AGENTS.md](../AGENTS.md) for the shared project instructions and
> [docs/verification.md](verification.md) for the verification system.

## Before modifying code

### What must be inspected

1. **README.md** — what Alice is and is not.
2. **AGENTS.md** — shared project instructions, contracts, verification
   steps, task checklist.
3. **docs/architecture.md** — complete system architecture.
4. **docs/verification.md** — what each test suite proves and does not.
5. **docs/compatibility-matrix.md** — implementation boundaries.
6. **SECURITY.md** — threat model and security boundaries.
7. **The nearest existing instructions** for the surface you are touching
   (e.g., `docs/purchases.md` for purchase changes).

### How to find the existing implementation

- **iOS:** `ios/Alice/Features/<Feature>/` for UI, `ios/Alice/Models/` for
  domain models, `ios/Alice/Networking/` for Hermes communication,
  `ios/Alice/Storage/` for persistence, `ios/Alice/Notifications/` for
  notifications.
- **Web:** `src/routes/` for pages, `src/components/` for UI,
  `src/lib/` for business logic. Use `rg` to search.
- **Plugin:** `hermes-plugin/` for Python code, `hermes-plugin/tests/`
  for tests.
- **Search first.** Use `rg --files` and `rg "<pattern>"` before writing
  anything. There is likely already an implementation, a test, or a
  contract guarding the behavior you need to change.

### How to identify the source of truth

See [docs/ARCHITECTURE.md §10](ARCHITECTURE.md#10-sources-of-truth) for
the complete table. Key sources:

| Data | Source of truth |
|------|----------------|
| Connection credentials | iOS Keychain (`KeyStore.swift`) |
| Conversations | Per-chat UserDefaults (`ConversationArchive.swift`) |
| Hermes state | Hermes gateway (`HermesClient.swift`) |
| Curated memory | Hermes filesystem (`MEMORY.md` / `USER.md`) |
| Web accounts | Neon Postgres (`user`, `session`, `account`) |
| Encrypted sync | Neon Postgres (`alice_sync_record`) |
| App preferences | UserDefaults (`AppStore.swift`) |

### When Git history must be checked

- **A behavior changed and you don't know why.** `git log -- <file>`
- **A test exists and you don't know what it guards.** `git log -p -- <test>`
- **A workaround looks odd.** The commit message likely explains why.
- **A regression appeared.** Check recent commits to the relevant code path.
- **You are about to remove code.** Check why it was added.
- **You are about to change a contract.** Check the commit that established it.
- **A fix commit exists for the area you're touching.** The fix likely
  documents the failure it prevents.

The 700+ commit history shows how features were specified, reviewed, and
fixed — including the fixes that followed real-world failures.

### When external research is required

- **Hermes API changed** — check the official Hermes source at the relevant
  tag/commit. Contract fixtures are in `src/lib/hermes-contract-fixtures.ts`.
- **Apple framework API** — check current Apple documentation for
  HealthKit, EventKit, CoreLocation, WidgetKit, etc.
- **Third-party service** — check the service's current API documentation.

### When current Apple documentation must be consulted

- **Any HealthKit API** — authorization, data types, background delivery.
- **Any EventKit API** — calendar/reminder access, changes.
- **Any CoreLocation API** — region monitoring, permissions.
- **Any WidgetKit API** — Live Activities, Lock Screen widgets.
- **Any BackgroundTasks API** — BGTaskScheduler, background fetch.
- **Any SwiftUI API** — navigation, keyboard, Dynamic Type, dark mode.
- **Any Keychain API** — access control, key class.
- **iOS 26 specific features** — Liquid Glass, new APIs.

## Implementation rules

### Smallest correct change

- Build on what exists. Justify every new dependency, abstraction, or
  service.
- Make the smallest coherent change that solves the problem.
- Avoid unrelated formatting and speculative rewrites.
- Check unfamiliar APIs in official docs before using them.

### Preserve existing architecture

- `AppStore.swift` is a large coordinator. New behavior should prefer
  focused modules. Extract existing behavior only with regression coverage.
- Do not split files just to hide coupling.
- The legacy web transport files need the same restraint.
- Preserve working boundaries before pursuing a larger refactor.
- Use the existing design system. Do not introduce new styles.

### No parallel implementations

- Do not create a second implementation of something that already exists.
- If you need a variant, extend the existing implementation.
- If the existing implementation is wrong, fix it — don't work around it.

### No duplicate state

- Do not create a second source of truth for data that already has one.
- If you need derived state, derive it from the source, don't copy it.
- The web client's read caches (30-second TTL) are not a second source of
  truth — they are explicitly invalidated on mutations.

### No speculative abstractions

- Do not add interfaces, protocols, or abstractions "for future use."
- Add an abstraction only when there is a concrete second implementation.
- The `HermesRPCTransport` protocol exists because there is a fake
  transport for testing. That's a real second implementation.

### No unrelated refactors

- Do not refactor code that is not related to your task.
- Do not rename variables, functions, or types that are not part of your
  change.
- Do not reformat code that is not part of your change.

### No silent UX changes

- Do not change copy, colors, spacing, or layout without explicit request.
- Do not change the order of operations without explicit request.
- Do not change error messages or notification text without explicit request.
- Destructive actions must clearly name their target.
- Never claim completion before the remote operation succeeds.

### No fallback logic without demonstrated failure mode

- Do not add `if x == nil { return defaultValue }` without evidence that
  `x` can actually be nil in production.
- Do not add try/catch that silently swallows errors.
- Do not add "just in case" checks for states that cannot occur.
- Every fallback must have a documented failure mode it protects against.

### Preserve lifecycle/cancellation/concurrency behavior

- Swift 6 strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY:
  complete`). Respect actor isolation.
- `AppStore` is `@MainActor @Observable`. Views read from it on the main
  actor.
- `HermesClient` is an `actor`. Do not break its isolation.
- `JSONObject` and `HermesRPCEvent` are `@unchecked Sendable` — they cross
  isolation boundaries per message.
- Preserve cancellation: `ChatTurnRoute`, `EventResume`, polling delays,
  sync cancellation between key derivation and network batches.
- All polling delays remove their timers immediately on abort.
- Account changes cancel work from the old account.

### No new dependency unless justified

- iOS has no third-party packages. Do not add SPM dependencies without
  strong justification.
- Web: `npm run deps:check` (Knip) fails on unlisted or unused packages.
- The plugin vendors its own dependencies to avoid touching Hermes'
  environment.
- Prefer existing native mechanisms where appropriate.

## Contracts that must survive changes

These are non-negotiable invariants from [AGENTS.md](../AGENTS.md):

### Connection identity

Home chat belongs to the installation's main profile. Bot chats carry
their own profile and canonical session. **Never silently reroute a
conversation, retry a write against another profile, or change its model.**

### Credentials

Validate origins before attaching secrets. Retain redirect protections.
Keep iOS secrets in Keychain. Direct web mode necessarily exposes its key
to JavaScript; do not promise otherwise. **Never log or commit secrets.**

### Data

Read old Codable archives before extending persisted models. A Swift
property default does not make synthesized decoding backward-compatible.
**Never replace an unreadable archive with an empty one.** Persist user
edits.

### Synchronization

Validate a recovery key before replacing the saved key or uploading
conversations. The account verifier is immutable. Save pulled records and
their cursor together. Account changes must cancel work from the old
account.

### Hermes

Use official, versioned source contracts and detected capabilities.
Preserve unknown stream events safely. A management endpoint may be
separate from the chat API. **Unsupported is different from empty, offline,
or unauthorized.**

### User experience

iOS first. Test keyboard, back navigation, Dynamic Type, dark mode,
reconnect, and interrupted requests. Destructive actions must clearly name
their target. **Never claim completion before the remote operation
succeeds.**

### Notifications

Distinguish an agent answer, routine delivery, failure, and approval.
iOS background execution is opportunistic. **Do not promise always-on
delivery while the app is closed.**

## Validation rules

### Validation proportional to change scope

See [docs/VALIDATION_TIERS.md](VALIDATION_TIERS.md) for the complete tier
system. Summary:

| Change type | Tier | What to run |
|-------------|------|-------------|
| Docs, comments, formatting | 0 | Format check, lint |
| Single function, no behavior change | 1 | Type check, lint, unit tests for area |
| Behavior change, new feature | 2 | + contract tests, build |
| Cross-surface change, PR | 3 | + E2E, security, deps |
| Release | 4 | Full validation + device review |

### Tests required by type of change

- **Bug fix:** Confirm the bug reproduces, then that the fix removes it.
  Add a regression test.
- **New feature:** Add unit tests for the new behavior. Add UI tests if
  the feature has a user-facing surface. Update the feature matrix.
- **iOS change:** `bash scripts/verify-ios.sh unit`. Navigation, layout,
  keyboard, or onboarding changes also require `ui` and visual review.
- **Web change:** `npm run check:static` and `npm run test:e2e`.
- **Plugin change:** `python -m unittest discover -s hermes-plugin/tests`.
- **Cross-surface change:** Check both transports, profile scoping, and
  `npm run slash:check`.

### When builds are justified

- After changing Swift code that compiles.
- After changing `ios/project.yml` (regenerate with XcodeGen).
- After changing build configuration.

### When UI testing is justified

- Navigation changes.
- Layout changes.
- Keyboard interactions.
- Onboarding changes.
- Dark mode or Dynamic Type changes.

### When manual verification is needed

- Physical device testing (the dev Mac has no simulator).
- Real Hermes interaction (fixture tests don't prove live behavior).
- Real purchases and payments.
- Background delivery (iOS controls this).
- Network conditions.

## Stop conditions

**STOP editing and investigate when:**

1. **You don't understand the existing implementation.** Read the code,
   tests, and Git history before making changes.
2. **A test fails and you don't know why.** Diagnose it; do not weaken the
   check or update snapshots merely to turn it green.
3. **You are about to change a contract.** Check
   [AGENTS.md](../AGENTS.md) and [docs/ARCHITECTURE_CONTRACTS.md](ARCHITECTURE_CONTRACTS.md).
4. **You are about to add a new dependency.** Justify it. Check if an
   existing mechanism suffices.
5. **You are about to change persistence.** Read old Codable archives
   before extending models. Never replace unreadable archives.
6. **You are about to change networking.** Preserve redirects, origin
   validation, cancellation, and lifecycle behavior.
7. **You are about to change streaming.** Preserve seq tracking, event
   resume, and unknown event handling.
8. **You are about to change concurrency.** Respect actor isolation,
   `@MainActor`, `Sendable`, and cancellation boundaries.
9. **You are about to change security.** Read [SECURITY.md](../SECURITY.md)
   and the pairing protocol. Never log or commit secrets.
10. **You are about to change the Hermes integration.** Check
    [docs/hermes-contracts.md](hermes-contracts.md). Use official, versioned
    contracts.
11. **You are about to claim completion.** The remote operation must have
    succeeded. A clean build does not prove a feature works.
12. **You are about to merge.** Do not merge to main. Open a draft PR.
13. **You are about to test with real data.** Never send prompts to, change
    settings on, or restart a person's real Hermes. Never test in the
    shared agent browser (127.0.0.1:9222).
14. **You are about to run the simulator on the dev Mac.** Do not. It
    depends on a simulator that makes the machine unusable.

## Regression rules

### How to diagnose a regression without layering patch upon patch

1. **Reproduce the regression.** Confirm it actually happens.
2. **Find the root cause.** Use `git bisect` or `git log -p` to find the
   commit that introduced it.
3. **Understand why the existing code didn't catch it.** Is there a missing
   test? A missing contract? A missing invariant?
4. **Fix the root cause.** Do not add a workaround on top of a broken
   implementation.
5. **Add a regression test** that would have caught the original failure.
6. **Generalize the lesson.** Can the same class of failure happen
   elsewhere? Add protection there too.

See [docs/FAILURE_LEARNINGS.md](FAILURE_LEARNINGS.md) for historical
failures and the protections derived from them.

## Refactor rules

### When a refactor is justified

- The existing code has a **demonstrated bug** that a refactor would fix.
- The existing code has a **measured performance problem** that a refactor
  would solve.
- The existing code **cannot be extended** without breaking a contract,
  and a narrow extraction would make it testable.
- The refactor is **the smallest change** that solves the problem.
- **Regression coverage exists** for the behavior being refactored.

### When a refactor is prohibited

- "The code is messy" — not a justification.
- "I would write it differently" — not a justification.
- "This could be more elegant" — not a justification.
- "Let me clean this up while I'm here" — not a justification.
- The refactor would change behavior, even slightly.
- The refactor would break backward compatibility of stored data.
- The refactor would change the public API without updating all consumers.
- The refactor is unrelated to the task at hand.
- `AppStore.swift` — extract only with regression coverage.
- Legacy web transports — need the same restraint.

## Dependency rules

### When new packages/services are acceptable

- The dependency solves a problem that cannot be solved with existing
  mechanisms.
- The dependency is well-maintained and has no known security issues.
- The dependency is justified in the PR description.
- `npm run deps:check` passes (no unlisted or unused packages).
- `npm run security:check` passes (no high+ vulnerabilities).
- The dependency does not duplicate existing functionality.
- For iOS: there are currently no third-party packages. Adding one requires
  exceptionally strong justification.

### When new packages/services are prohibited

- An existing native mechanism suffices.
- The dependency duplicates existing functionality.
- The dependency is unmaintained.
- The dependency has known security issues.
- The dependency is added "for convenience" without a concrete use case.
- The dependency would touch Hermes' environment (plugin must vendor its
  own).

## Output contract

Every coding task must finish by reporting:

### Files changed
List every file modified, created, or deleted.

### Behavior changed
What the user can now do that they couldn't before, or what works
differently.

### Architectural effects
What contracts, invariants, or boundaries are affected. What new state,
dependencies, or abstractions were introduced.

### Tests/checks run
Exact commands and results. Distinguish:
- **Checked** (with the evidence)
- **Not checkable here** (on this Mac: anything visual on screen, since
  there is no simulator; real purchases and payments; the model's behavior
  in a live conversation)
- **Remaining risk**

### Checks intentionally not run and why
e.g., "Simulator UI tests not run — the development Mac has no simulator."
e.g., "Live contract test not run — no test Hermes available."
e.g., "Physical device test not run — no device connected."

### Remaining risks
What could still go wrong. What was not verified. What assumptions were
made.

### Uncertainty
What you don't know. What would resolve it. Mark as **UNKNOWN** where
appropriate.

### Rollback instructions (when relevant)
How to undo the change. What to watch for after rolling back.

## Alice-specific rules

### iPhone builds

- The build number only goes up (passed to `xcodebuild` as
  `CURRENT_PROJECT_VERSION`, never set in `project.yml`).
- Before saying an install arrived, read the version off the device:
  `xcrun devicectl device info apps`.
- Never commit generated Xcode projects, credentials, build outputs, or
  local data.

### Plugin deployment

- Back up `~/.hermes/plugins/alice` to `~/.hermes/backups/` before
  deploying.
- Then restart `ai.hermes.gateway` and, after it answers,
  `ai.hermes.dashboard` — one at a time.

### Testing boundaries

- **Never test in the person's shared agent browser** (CDP on
  127.0.0.1:9222). Use a separate temporary Chrome on another port.
- **Never run `scripts/verify-ios.sh` on the development Mac.** It depends
  on a simulator that makes the machine unusable.
- **Never send prompts to, change settings on, or restart a person's real
  Hermes** as part of routine tests.
- **Never run UI tests on the user's real iPhone** (real data).
- **Read-only live contract checks** must be clearly distinguished from
  fixture tests.

### Every report ends with three parts

1. **Checked** (with the evidence)
2. **Not checkable here** (on this Mac: anything visual on screen, since
   there is no simulator; real purchases and payments; the model's
   behavior in a live conversation)
3. **Remaining risk**

The question that matters most at the end: _what evidence shows this
change does what was asked and keeps what already worked?_
