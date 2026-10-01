# Alice — Operations

How to build, run, verify and operate each surface. Everything here is a
command or configuration that exists in the repository. **UNKNOWN** marks
missing evidence.

## Prerequisites

| Surface | Requirement | Evidence |
| --- | --- | --- |
| iOS | Mac with Xcode 26, XcodeGen, Apple developer account; iPhone with iOS 26 | [README.md](../README.md) "You need" |
| Hermes | Hermes 0.21.x with a model provider, self-run | [README.md](../README.md) |
| Web | Node 22.13+ (22.x line) or Node 24+, npm 11.19.0 | `package.json` engines, `docs/verification.md` |
| Plugin | Hermes Python environment with dashboard dependencies | `docs/verification.md` |
| Secrets | Gitleaks for scanning; `HERMES_COOKIE_SECRET` for any kept deployment | `docs/verification.md`, `.env.example` |

## Building and running

### iOS

```bash
# Generate the project (never commit Alice.xcodeproj)
cd ios && xcodegen generate

# Local verification on a machine with simulators (CI or a capable Mac)
bash scripts/verify-ios.sh unit     # unit tests on the "Alice Verification" simulator
bash scripts/verify-ios.sh ui       # UI tests
bash scripts/verify-ios.sh all      # both (45-minute CI budget)
bash scripts/verify-ios.sh build    # compile only
```

`verify-ios.sh` reuses only the dedicated "Alice Verification" simulator —
"a developer's ordinary simulator may contain real gateway credentials and
must not be selected automatically" (`scripts/verify-ios.sh`).
`ALICE_SIMULATOR_ID` and `ALICE_DERIVED_DATA_PATH` override the
environment. `performance` mode refuses to run outside GitHub Actions
(local simulator benchmarks are disabled).

**The development Mac has no simulators on purpose** (booting one made the
machine unusable — `AGENTS.md` "This Mac" section). Physical-device build:

```bash
xcodebuild -project ios/Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
```

Build numbers only go up (`CURRENT_PROJECT_VERSION` passed to `xcodebuild`,
never set in `project.yml`); read the installed version back with
`xcrun devicectl device info apps` before claiming an install arrived
(`AGENTS.md` Alice specifics).

### Hermes plugin (Mac side)

```bash
hermes-plugin/install.sh   # copies to ~/.hermes/plugins/alice, enables it
```

Installs `pypdf==6.18.0` into the plugin's own `vendor/` folder; restarts
the Hermes dashboard on macOS. "Restart any running Hermes gateway too:
Hermes loads plugins once per process" ([README.md](../README.md) step 1).

Deploying a plugin update to the live Mac: back up
`~/.hermes/plugins/alice` to `~/.hermes/backups/` first, **merge, never
overwrite**, then restart `ai.hermes.gateway` and, after it answers,
`ai.hermes.dashboard` — one at a time (`AGENTS.md` Alice specifics,
`docs/HANDOFF.md`).

### Web client

```bash
npm ci                                  # with the pinned npm version
npm run dev                             # Vite dev server on 0.0.0.0:8080 (env-wrapped)
npm run build                           # production build
npm run db:migrate                      # apply migrations/ to a production database
node scripts/phone.mjs                  # expose the app at the tailnet MagicDNS name
```

`scripts/with-app-env.mjs` wraps dev/build so environment flows in
controlledly; `scripts/phone.mjs` requires Tailscale and uses Funnel
because "Safari on iPhone … will not complete TLS against Serve-only"
(`scripts/phone.mjs` docstring). Production is Vercel + Neon Postgres
(`vercel.json`, `.env.example` comments, `docs/release-operations.md`).

### Mac notifier

```bash
python -m unittest discover -s mac/notifier     # tests
mac/notifier/install.sh                          # install (see script)
```

Standard library only, Python 3.9+; Bark key in the login Keychain under
service `alice-bark` (`alice_notifier.py`).

## Static checks (web)

`npm run check:static` chains: `format:check`, `lint`, `typecheck`,
`typecheck:contracts` (strict ratchet), `test`, `test:coverage`,
`cycles:check` (madge), `duplicates:check` (jscpd), `design:check`,
`ios:render-check`, `slash:check`, `build:ci`, `bundle:smoke`,
`bundles:check` (`package.json` scripts). `npm run check` adds `test:e2e`.
`npm run ci:local` wraps the local approximation (`scripts/ci-local.sh`).

## Environments and configuration

- Web server env: `HERMES_COOKIE_SECRET` (or `HERMES_COOKIE_KEYS`, or
  `BETTER_AUTH_SECRET` fallback) — required in production; dev may use
  `~/.alice/hermes-credential.key` (`SECURITY.md`).
- Owner model: `ALICE_OWNER_EMAIL` (no owner access without it),
  `ALICE_OWNER_CLAIM_LOCAL` (one-time local promotion), `ALICE_OWNER_NAME`,
  `ALICE_OWNER_PASSWORD`, Google OAuth `GOOGLE_CLIENT_ID/SECRET`
  (`.env.example`).
- Production env: `DATABASE_URL` (Neon), `BETTER_AUTH_URL`,
  `VITE_AUTH_ENABLED` (`.env.example`).
- Release identity: every API response carries `X-Alice-Version` and
  `X-Alice-Environment`; `GET /api/status` returns the same identity with
  `Cache-Control: no-store` (`docs/release-operations.md`,
  `src/routes/api/status.ts`).

## Runtime telemetry

Two machine-readable record types in logs: `alice_operational` (bounded
anonymous measurements) and `alice_alert` (stable codes, warning/critical
severity). The Zod contract rejects prompts, responses, identifiers,
Hermes URLs, keys and arbitrary error text; successful requests sampled at
10%; Vercel runtime logs are the only production sink, retention ≤ 30 days
(`docs/operational-telemetry.md`). Page on every `critical`, notify on
`warning`; repeated alerts are cooled down one minute per code/route/metric
(`docs/release-operations.md`).

## Local machine access and safety rails

- Only the configured, verified owner may use local Hermes access with
  authentication enabled (`SECURITY.md`, `src/lib/auth/owner.server.ts`).
- The outbound HTTP guard pins fetches and rejects private hostnames in
  public contexts (`src/lib/outbound-http.server.ts`).
- **Never test in the person's shared agent browser (CDP on
  127.0.0.1:9222)**; use a separate temporary Chrome on another port
  (`AGENTS.md` Alice specifics). The plugin's own shared browser is
  headless with its own profile at `<hermes home>/chrome-debug`
  (`browser_live.py`).
- Do not send prompts to, change settings on, or restart a person's real
  Hermes as part of routine tests (`AGENTS.md` Verification).

## Day-2 operations on the phone

- Developer mode (Settings › Advanced) adds the Developer pane:
  DiagnosticChecks (Hermes reachability/latency, plugin present, one
  timezone per agent, calendar, notifications, Bark, routines, storage
  size, freezes in the last 10 minutes via `HitchMonitor`, unrecognized
  Hermes messages), a performance meter, the component gallery, and
  diagnostics upload (`docs/verification.md`, `ios/Alice/Features/Developer/`).
- The plugin answers `alice_app_status` / `alice_recent_errors` from an
  uploaded diagnostic dump (`hermes-plugin/plugin.yaml`).
- A debug build writes each main-thread freeze to the diagnostics log with
  the functions involved (`stall.in`, `stall.at`). "A stall of many
  seconds whose stack is the resume path is the app having been suspended,
  not a hitch" (`docs/verification.md`).

## Rollback

Web: promote the last known-good immutable Vercel deployment to the
production alias (do not rebuild), verify with
`npm run release:verify -- https://…`, then exercise login, `/connect`, one
Hermes read and one chat request (`docs/release-operations.md`).
Database changes remain additive so a code rollback never requires a
destructive database rollback.

iOS: reinstall the previous build (build numbers only go up); there is no
store channel — distribution is sideloading via `devicectl`
(`AGENTS.md`).

Plugin: restore from `~/.hermes/backups/plugin-alice-*` and restart the
gateway then the dashboard (`docs/HANDOFF.md`).
