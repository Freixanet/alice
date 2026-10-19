# Operations

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

## Daily operations

### Building and installing the iOS app

The development Mac (Intel, 16 GB) has no iOS simulators. Build for a
physical device:

```bash
cd ios && xcodegen generate
xcodebuild -project Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE-UDID> \
  ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
```

Read the version off the device to confirm installation:
```bash
xcrun devicectl device info apps
```

The build number only goes up. Pass `CURRENT_PROJECT_VERSION` to `xcodebuild`,
never set it in `project.yml`. ([AGENTS.md](../AGENTS.md))

### Deploying the Hermes plugin

```bash
# 1. Back up the live plugin
cp -R ~/.hermes/plugins/alice ~/.hermes/backups/plugin-alice-$(date +%Y%m%d)

# 2. Compare and merge (never just overwrite)
diff -r ~/.hermes/plugins/alice hermes-plugin/

# 3. Install
hermes-plugin/install.sh

# 4. Restart services (one at a time)
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway
# Wait for gateway to answer
launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard
```

Hermes loads plugins once per process. The gateway and dashboard must be
restarted after plugin updates. ([AGENTS.md](../AGENTS.md),
[docs/HANDOFF.md](HANDOFF.md))

### Running checks locally

```bash
# Full local CI (pre-push equivalent)
bash scripts/ci-local.sh all

# Just the verify job (fastest, most important)
bash scripts/ci-local.sh verify

# Web static checks only
npm ci && npm run check:static

# Plugin tests
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests

# Notifier tests
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s mac/notifier

# Secret scan
gitleaks detect --source=. --no-banner --redact
```

([docs/verification.md](verification.md))

### iOS simulator tests (CI only)

```bash
# In CI (macos-26 runner):
bash scripts/verify-ios.sh all    # unit + UI tests
bash scripts/verify-ios.sh unit   # unit only
bash scripts/verify-ios.sh ui     # UI only
bash scripts/verify-ios.sh build  # build only
```

Never run `verify-ios.sh` on the development Mac. It depends on a simulator
that would make the machine unusable. ([AGENTS.md](../AGENTS.md))

### Web development

```bash
npm ci
npm run dev    # Vite dev server on 0.0.0.0:8080
```

If another checkout or CI run uses port 8091, set `ALICE_E2E_PORT` to a free
port for Playwright. Each checkout must have its own running test server.

### Deploying the web companion

The web companion deploys to Vercel. Every deployment includes
`X-Alice-Version` and `X-Alice-Environment` headers.

```bash
# Verify a deployment
npm run release:verify -- https://alice-ten-phi.vercel.app
```

Database changes are additive and backward-compatible. Run
`npm run db:migrate` against the production database before promoting.
Migration `0005_sync_verifier.sql` is compatible with older application code.

([docs/release-operations.md](release-operations.md))

## Monitoring

### Release identity

Every API response includes `X-Alice-Version` and `X-Alice-Environment`.
`GET /api/status` returns the same closed release identity with
`Cache-Control: no-store`. It contains no deployment URL, account identifier
or secret. ([docs/release-operations.md](release-operations.md))

### Operational telemetry

Two machine-readable record types in runtime logs:

- `alice_operational` — bounded anonymous measurements
- `alice_alert` — stable alert codes with `warning` or `critical` severity

Configure the production log monitor to:
- Page on every `critical` Alice alert
- Notify the engineering channel on `warning`
- Keep logs for no more than 30 days

The monitor excludes prompts, responses, user/account identifiers, Hermes
addresses, filenames and arbitrary error text.

Immediate critical signals:
- Server and sync failures
- Severely slow local handlers
- Severely degraded Web Vitals

Burst thresholds protect auth, client-runtime and Hermes-connection alerts
from isolated noise. Repeated alerts are cooled down for one minute per code,
route and metric.

([docs/operational-telemetry.md](operational-telemetry.md),
[docs/release-operations.md](release-operations.md))

### iOS diagnostics

Settings → Advanced → Developer mode → Settings → Developer:

- **Checks** (`DiagnosticChecks.swift`): Hermes reachability/latency, Alice
  plugin, time zone consistency, calendar, notifications, proactive
  routines, storage size, freezes in last 10 minutes, unknown Hermes events.
- **Performance meter**: FPS, late frames, freezes beside the home indicator.
  Debug builds write each freeze to the diagnostics log with main-thread
  stack (`stall.in`, `stall.at`).
- **Tools**: component gallery, share report, send diagnostics to Hermes,
  test notification, resets.
- **Recent activity** from `DiagnosticsLog` — ids, states, timings (never
  message text).

([docs/verification.md](verification.md))

## Rollback

### Web companion rollback

1. Select the last known-good immutable Vercel deployment.
2. Promote that deployment to the production alias; do not rebuild.
3. Run the release verifier against the production alias.
4. Confirm the version matches the selected deployment.
5. Exercise login, `/connect`, one Hermes read, one chat request.
6. Preserve failed release logs and open a corrective change from `main`.

Database changes are additive, so a code rollback never requires a
destructive database rollback. ([docs/release-operations.md](release-operations.md))

### iOS rollback

Build and install the previous version from `main` or the relevant commit.
The build number only goes up; a rollback installs a lower build number on
top.

### Plugin rollback

```bash
# Restore from backup
cp -R ~/.hermes/backups/plugin-alice-YYYYMMDD/. ~/.hermes/plugins/alice/
# Restart services
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway
launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard
```

## Git hooks

The pre-push hook (`.githooks/pre-push`) runs `ci-local.sh verify` — the
Quality workflow's verify job locally. This exists because GitHub Actions
billing was unsettled at one point. The hook runs only the fast checks
(typically 2–5 minutes).

```bash
# Push without the gate (deliberate)
SKIP_CI=1 git push
```

The hook is installed via `package.json`'s `prepare` script:
`git config core.hooksPath .githooks`.

## CI workflows

### Quality workflow

Runs on every pull request and push to `main`. Three jobs:

1. **verify** (ubuntu-latest, 25 min): gitleaks, npm ci, check:static,
   security:check, deps:check, build, bundles:check, plugin tests, notifier
   tests.
2. **browser** (ubuntu-latest, 25 min): npm ci, Playwright install, test:e2e.
3. **ios** (macos-26, 45 min): XcodeGen, verify-ios.sh all.

Concurrency: PR pushes cancel older runs; main pushes are always checked.

### iOS Performance workflow

Runs on changes to `ios/AlicePerformanceTests/`, `ios/project.yml`,
`scripts/verify-ios.sh`, or `scripts/ios_performance_summary.py`. Also
dispatchable manually.

Measures 5 iterations of: responsive launch into 30 long reports, scroll
back, open Agents, return to chat. Retains raw `.xcresult`, CSV metrics,
and a summary for 30 days.

([.github/workflows/quality.yml](../.github/workflows/quality.yml),
[.github/workflows/ios-performance.yml](../.github/workflows/ios-performance.yml))

## Environment variables

| Variable | Where | Purpose | Required |
|----------|-------|---------|----------|
| `HERMES_COOKIE_SECRET` | Server (Vercel) | Encrypts connection cookie | Production |
| `DATABASE_URL` | Server (Vercel + Neon) | Postgres connection | Production |
| `BETTER_AUTH_URL` | Server | Auth callback URL | Production |
| `BETTER_AUTH_SECRET` | Server | Auth session signing | Production |
| `VITE_AUTH_ENABLED` | Build | Enable web auth | Production |
| `ALICE_OWNER_EMAIL` | Server | Owner identity | Production |
| `ALICE_OWNER_CLAIM_LOCAL` | Server | Promote local account | Setup only |
| `ALICE_OWNER_NAME` | Server | Owner display name | Setup only |
| `ALICE_OWNER_PASSWORD` | Server | Password login | Optional |
| `GOOGLE_CLIENT_ID` | Server | Google OAuth | Optional |
| `GOOGLE_CLIENT_SECRET` | Server | Google OAuth | Optional |
| `ALICE_SIMULATOR_ID` | iOS CI | Override simulator | Optional |
| `ALICE_DERIVED_DATA_PATH` | iOS CI | Override build path | Optional |
| `ALICE_E2E_PORT` | Web E2E | Override Playwright port | Optional |
| `HERMES_LIVE_URL` | Live contract test | Test Hermes endpoint | Test only |
| `HERMES_LIVE_KEY` | Live contract test | Test Hermes key | Test only |

([.env.example](../.env.example))
