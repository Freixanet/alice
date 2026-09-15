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
`all` runs both suites; `build` compiles without running tests.

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
