# Verification and release evidence

## Prerequisites

- iOS: macOS, Xcode with iOS 26 SDK/runtime and XcodeGen.
- Web: Node 22.13+ in the 22.x line, or Node 24+; npm 11.19.0.
- Plugin: a Hermes Python environment with its dashboard dependencies.
- Secret scan: Gitleaks. Never include private transcripts or QR credentials in artifacts.

## Native app first

```bash
bash scripts/verify-ios.sh unit
bash scripts/verify-ios.sh ui
```

The script creates/reuses a simulator named **Alice Verification**. It does not
select a developer's personal simulator. `ALICE_SIMULATOR_ID` and
`ALICE_DERIVED_DATA_PATH` can explicitly override its test environment.
`all` runs both suites; `build` compiles without running tests. Cold simulator
startup and UI automation can take considerably longer than unit tests; CI
allows 45 minutes for the complete native job without changing test assertions.

For a release, also review on a physical iPhone: fresh pairing, camera permission
denial, loss of network, app suspension, long responses, attachments, keyboard
navigation, large text and a reconnect after the Hermes host restarts. Simulator
tests cannot establish background delivery, camera behavior or all network
conditions on a real phone. Validate iPad layout before claiming iPad readiness.

## Web companion

```bash
npm ci
npm run check:static
npm run test:e2e
npm run security:check
npm run deps:check
```

The browser suite uses an isolated local database and disables authentication.
It therefore does **not** establish that registration, OAuth or account recovery
work in production. Verify those flows separately using test accounts.

If another checkout or CI run uses port 8091, set `ALICE_E2E_PORT` to a free
port for Playwright. Each checkout must have its own running test server.

The mobile web-vitals test runs against the Vite development server. Its INP
window opens after one untimed keystroke: the first key typed into any text field
costs Chromium on macOS about 200 ms before the next frame even on a page with
only a `<textarea>` (232–296 ms measured, Chrome and Playwright Chromium alike).
Field INP for a person's first keystroke includes that platform cost; the test
budget measures Alice's own responsiveness. Budgets themselves are unchanged.

On a loaded machine, run coverage with `npm run test:coverage -- --maxWorkers=2`.
If a database bootstrap times out, repeat the affected suite without concurrent
Xcode builds. Record both results; do not hide a failure by changing assertions.

## Plugin and optional notifier

```bash
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s mac/notifier
gitleaks detect --source=. --no-banner --redact
```

## Hermes updates

1. Read the official release notes and compare changed source contracts at a tag.
2. Update fixtures and their exact source commits; preserve older regression cases.
3. Test direct, proxy and native behavior for changed operations and unknown fields.
4. Run the read-only live contract check against a dedicated test installation:
   `npm run test:hermes:live` with `HERMES_LIVE_URL` and `HERMES_LIVE_KEY` supplied
   through the environment, never pasted into an issue or committed file.
5. Exercise real chat, approvals, cancellation, canonical sessions and reconnect
   only in an explicitly designated test agent. A manifest alone is insufficient.

## Evidence to attach to a release

Record the Alice commit, Hermes version/commit, toolchain, commands, results,
screenshots and omissions. Keep fixture, simulator, physical-device and live
service results distinct. Check migrations and backups, production secrets and
database configuration, signing/distribution and rollback before release.

A badge describes a workflow run. It is not a certification of every feature.

## Developer mode on the phone

Settings › Advanced › Developer mode adds **Settings › Developer**:

- **Checks** (`Features/Developer/DiagnosticChecks.swift`): Hermes reachability
  and latency, the Alice plugin, one time zone for every agent, calendar,
  notifications and Bark, the proactive routines, storage size, freezes this
  session (`HitchMonitor`) and Hermes messages Alice does not understand yet.
  A feature that can break adds its own `DiagnosticCheck` to `all`.
- **Performance meter**: frames per second, late frames and freezes, beside
  the home indicator. A debug build writes each freeze to the diagnostics log
  with the functions the main thread was in (`stall.in`, `stall.at`). A stall
  of many seconds whose stack is the resume path is the app having been
  suspended, not a hitch while it was on screen.
- **Tools**: component gallery (every rich block and card, Spanish and
  English), share a report, send diagnostics to Hermes, a test notification,
  and resets.
- **Recent activity** from `DiagnosticsLog` — ids, states and timings, never
  message text — and the build.

These run against the real Hermes and phone: they read, and only the tools
write (a test notification, a diagnostics upload, a card's own action).

## Native performance measurements

Run **iOS Performance** from GitHub Actions (or `gh workflow run ios-performance.yml
--ref <branch>`). It runs automatically when its harness changes. The dedicated
`AlicePerformance` scheme measures five iterations of a responsive launch into
30 long reports, scrolling back to the latest report, and opening Agents then
returning to chat. Each journey checks that its destination was actually reached.
The normal `Alice` scheme keeps all unit and UI correctness tests, without adding
benchmark repetitions to every app change.

The workflow retains raw `.xcresult`, per-iteration CSV metrics and a compact job
summary for 30 days. Record the commit, Xcode/iOS versions and fixture with every
comparison. XCTest records launch duration and journey wall time, app CPU use and
memory. Journey wall time includes UI automation and idle waits: it is not pure
rendering latency. These are Debug simulator baselines, not physical iPhone,
Release, cold-device boot, network/model latency, scroll frame-rate or battery
measurements. Repeated launches benefit from warmed system caches. One
run is not evidence of an improvement; compare repeated runs under matched
conditions before setting a regression budget.

`scripts/verify-ios.sh performance` refuses local execution outside GitHub Actions.
This Mac must not boot a simulator. Generic-device test-bundle compilation is
allowed; never point this harness at the person's iPhone or real Hermes. The CI
runner has only synthetic fixtures and no Hermes credentials. For physical-device
hitches, use the existing Developer performance meter and diagnostic report during
normal use; do not fabricate device results from simulator measurements.
