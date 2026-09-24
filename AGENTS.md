# Working on Alice

Alice is primarily a native iPhone app for a user's own Hermes agent. The web
client and Hermes dashboard plugin are companion surfaces. Preserve useful
features while making everyday use simpler. Do not treat a clean build as proof
that a feature works against Hermes.

## Start here, in any coding tool

1. Read `README.md`, `docs/architecture.md`, `SECURITY.md` and the nearest instructions.
2. Check `git status --short`, the branch and the base commit. Preserve existing
   changes. Read `docs/verification.md` and `docs/compatibility-matrix.md` before
   claiming release readiness.
3. Identify the affected surface and its tests. Work on a topic branch. Make the
   smallest coherent change; avoid unrelated formatting and speculative rewrites.

This file is the shared source of instructions for Codex, Claude Code, Cursor
and other tools. Tool-specific files point here rather than duplicate policy.

## Contracts that must survive changes

- **Connection identity:** home chat belongs to the installation's main profile.
  Bot chats carry their own profile and canonical session. Never silently reroute
  a conversation, retry a write against another profile or change its model.
- **Credentials:** validate origins before attaching secrets; retain redirect
  protections. Keep iOS secrets in Keychain. Direct web mode necessarily exposes
  its key to JavaScript; do not promise otherwise. Never log or commit secrets.
- **Data:** read old Codable archives before extending persisted models. A Swift
  property default does not make synthesized decoding backward-compatible.
  Never replace an unreadable archive with an empty one. Persist user edits.
- **Synchronization:** validate a recovery key before replacing the saved key or
  uploading conversations. The account verifier is immutable. Save pulled records
  and their cursor together; account changes must cancel work from the old account.
- **Hermes:** use official, versioned source contracts and detected capabilities.
  Preserve unknown stream events safely. A management endpoint may be separate
  from the chat API. Unsupported is different from empty, offline or unauthorized.
- **User experience:** iOS first; test keyboard, back navigation, Dynamic Type,
  dark mode, reconnect and interrupted requests. Destructive actions must clearly
  name their target. Never claim completion before the remote operation succeeds.
- **Notifications:** distinguish an agent answer, routine delivery, failure and
  approval. iOS background execution is opportunistic; do not promise always-on
  delivery while the app is closed.

## Verification

- iOS code: `bash scripts/verify-ios.sh unit`; navigation, layout, keyboard or
  onboarding changes also require `bash scripts/verify-ios.sh ui` and visual review.
- Web: `npm ci` with the pinned npm version, then `npm run check:static` and
  `npm run test:e2e`. Run `npm run security:check` and `npm run deps:check` for releases.
- Plugin: use the Hermes virtualenv to run `python -m unittest discover -s hermes-plugin/tests`.
- Notifier: `python -m unittest discover -s mac/notifier`.
- Cross-surface changes: check both transports, profile scoping and
  `npm run slash:check`. Regenerate `ios/Alice.xcodeproj` from `ios/project.yml`;
  never commit generated Xcode projects, credentials, build outputs or local data.
- Use an isolated simulator and test data. Do not send prompts to, change settings
  on, or restart a person's real Hermes as part of routine tests. Read-only live
  contract checks must be clearly distinguished from fixture tests.

### This Mac: physical iPhone only, no simulator

This Mac (Intel, 16 GB) has no iOS simulators or simulator runtimes installed, on
purpose: booting one made the machine unusable. Do not create simulators, download
simulator runtimes (`xcodebuild -downloadPlatform`), or run `scripts/verify-ios.sh`
here; it depends on a simulator. To ship a change to the user's iPhone:

```bash
xcodebuild -project ios/Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
```

A successful device build is the local iOS check. Report that simulator unit/UI
tests were not run; never run UI tests on the user's real iPhone (real data).

Record exact commands, results and important omissions in the PR. If a check
fails, diagnose it; do not weaken the check or update snapshots merely to turn it
green. Do not merge, tag, deploy or claim universal compatibility from incomplete
evidence. The user's explicit instructions determine publication authorization.

## Task checklist: close every task with evidence

Apply to every task. Tick only what was actually checked; say when an item does
not apply; leave anything that could not be checked as pending. A test that was
defined but not run is still pending.

**Before changing code**

- [ ] Understand the project: read instructions, files, patterns, dependencies and
      existing commands. Preserve other people's changes.
- [ ] Define the outcome: what the person should be able to do, what they should
      get, and what is out of scope. Resolve only the questions that would change the
      solution significantly.
- [ ] Choose the smallest solution: build on what exists. Justify every new
      dependency, abstraction or service. Check unfamiliar APIs in official docs.

**While implementing**

- [ ] Cover the whole path: input → action → result → persistence where it
      applies, including empty, loading, error and recovery states.
- [ ] Protect data and actions: validate input, check permissions where the
      operation runs, never expose secrets. Consider double submission, concurrency
      and network failure when they affect the task.
- [ ] Care for the real interface: reuse components and styles; check hierarchy,
      copy, layout at every size, keyboard, focus and contrast. Inspect the rendered
      result.
- [ ] Preserve what already works: keep contracts and existing behaviour unless a
      change was asked for. Avoid edits unrelated to the goal.

**Before calling it done**

- [ ] Check the behaviour: verify the acceptance criteria and the important
      failures. Add tests that catch relevant regressions; for a bug, confirm it
      reproduces and that the fix removes it.
- [ ] Run the checks that apply: tests, types, lint and build. Never disable a
      check or change an expectation just to make it pass.
- [ ] Review the whole diff: accidental changes, unnecessary code, secrets,
      incompatibilities and documentation left wrong.
- [ ] Report precisely: what changed, what was checked, what could not be checked
      and what risk remains.

**If it ships**

- [ ] Check delivery and recovery: know the version and where it went, how to
      roll back, and test the main flow after deploying. Review migrations when data
      changes.

**Alice specifics**

- [ ] iPhone builds: the build number only goes up (passed to `xcodebuild` as
      `CURRENT_PROJECT_VERSION`, never set in `project.yml`). Before saying an install
      arrived, read the version off the device (`xcrun devicectl device info apps`).
- [ ] The Mac's Hermes plugin: back up `~/.hermes/plugins/alice` to
      `~/.hermes/backups/` before deploying, then restart `ai.hermes.gateway` and, after
      it answers, `ai.hermes.dashboard` — one at a time.
- [ ] Never test in the person's shared agent browser (CDP on 127.0.0.1:9222); use
      a separate temporary Chrome on another port.
- [ ] End every report with three parts: **checked** (with the evidence),
      **not checkable here** (on this Mac: anything visual on screen, since there is no
      simulator; real purchases and payments; the model's behaviour in a live
      conversation) and **remaining risk**.

The question that matters most at the end: _what evidence shows this change does
what was asked and keeps what already worked?_

## Keep the project maintainable

New behavior belongs in a focused service, model or feature module. Avoid further
growth of `AppStore.swift` and the legacy web transports when a narrow extraction
can be tested. Preserve working boundaries before pursuing a larger refactor.
Use the existing design system. Update the feature matrix and user guide when
capabilities or setup steps change. Keep factual documentation concise, current
and honest about what was actually tested.
