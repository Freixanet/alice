# Alice Operations Guide

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document captures operational knowledge that was previously implicit or
existed only in developers' memory. A competent new engineer should not need
to ask anyone how Alice works operationally after reading this.

## Quick reference

| What                    | Command / Location                                    |
| ----------------------- | ----------------------------------------------------- |
| Health check            | `bash scripts/alice-doctor.sh`                        |
| Backup                  | `bash scripts/backup-alice.sh`                        |
| Web CI (local)          | `npm run ci:local`                                    |
| iOS unit tests          | `bash scripts/verify-ios.sh unit`                     |
| iOS UI tests            | `bash scripts/verify-ios.sh ui`                       |
| iOS device build        | See "Building for iPhone" below                        |
| Plugin tests            | `python -m unittest discover -s hermes-plugin/tests`   |
| Notifier tests          | `python -m unittest discover -s mac/notifier`           |
| Web static checks       | `npm run check:static`                                |
| Web E2E tests           | `npm run test:e2e`                                    |
| DB migration            | `npm run db:migrate`                                  |
| Release verification    | `npm run release:verify -- <url>`                     |
| Pre-push hook           | `.githooks/pre-push` (runs `scripts/ci-local.sh verify`) |

## Starting Hermes

Hermes runs as two launchd services on macOS:

1. **Gateway** (`ai.hermes.gateway`): serves the agent API on a local port.
2. **Dashboard** (`ai.hermes.dashboard`): serves the management UI and plugin
   on port 9119.

### Starting the gateway

```bash
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway
```

Or if the service is not loaded, start it through Hermes:

```bash
hermes gateway start
```

The gateway port is configured in the profile's `.env` file at
`~/.hermes/profiles/<name>/.env` as `API_SERVER_PORT`. The main profile uses
ports starting at 8643; bot gateways use 8642.

### Starting the dashboard

```bash
launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard
```

The dashboard runs on port 9119 by default. It serves the management UI at
`http://localhost:9119` and plugin endpoints at
`http://localhost:9119/api/plugins/alice/`.

### Restart order

When restarting both: **gateway first, then dashboard, one at a time.** The
dashboard may depend on the gateway being available. After restarting, verify
with `bash scripts/alice-doctor.sh`.

### Hermes CLI

The `hermes` command should be in PATH after installation. If not, it lives at
`~/.hermes/hermes-agent/venv/bin/hermes`. The Python virtualenv is at
`~/.hermes/hermes-agent/venv/`.

## Starting the Alice backend (plugin)

The Alice plugin is part of the Hermes dashboard — it does not run as a
separate process. It is installed with:

```bash
hermes-plugin/install.sh
```

This copies the plugin to `~/.hermes/plugins/alice/`, enables it, and restarts
the dashboard if running. After installation, the Alice tab appears in the
Hermes dashboard.

### Updating the plugin

1. Back up the existing plugin: `cp -r ~/.hermes/plugins/alice
   ~/.hermes/backups/plugin-alice-$(date +%Y%m%d)`
2. Re-run `hermes-plugin/install.sh`.
3. Restart the dashboard: `launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard`
4. Restart the gateway (plugins load once per process):
   `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway`

## Mac requirements

| Requirement          | Version      | Purpose                          |
| -------------------- | ------------ | -------------------------------- |
| macOS                | Latest      | Development and Hermes host      |
| Xcode                | 26          | iOS builds and simulator tests   |
| XcodeGen             | Latest      | Generate Xcode project           |
| Node.js              | 22.13+ or 24+ | Web companion development      |
| npm                  | 11+         | Dependency management            |
| Python               | 3.9+        | Plugin and notifier              |
| Hermes               | 0.21.x      | Agent runtime                    |
| Tailscale (optional) | Latest      | iPhone ↔ Mac networking          |
| Chromium (optional)  | Any         | Shared browser feature           |

### This Mac (development machine)

This is an Intel Mac with 16 GB RAM. **No iOS simulator is installed on
purpose** — booting one made the machine unusable. Do not:
- Create simulators
- Download simulator runtimes (`xcodebuild -downloadPlatform`)
- Run `scripts/verify-ios.sh` locally (it requires a simulator)

iOS testing is done by building for a physical device or running CI.

## iPhone ↔ Mac pairing

### QR pairing (preferred)

1. Both devices on the same network or Tailscale.
2. Hermes dashboard → Alice tab → Show pairing code.
3. iPhone: open Camera, scan the QR, or use Connect → Scan pairing QR in Alice.
4. Confirm device name, tap Connect.
5. Alice saves gateway and dashboard credentials in Keychain.

The QR contains `alice://pair?v=1&p=<base64url(json)>` with a one-time token.
The token expires in 5 minutes and can only be used once.

### Manual connection

1. In Alice: Connect → enter Hermes address and gateway key.
2. The gateway address is `http://<mac-ip>:<port>` or the Tailscale hostname.
3. The gateway key is `API_SERVER_KEY` from the profile's `.env`.

### Gateway provisioning

When pairing, the plugin provisions the main profile's gateway if it doesn't
have one:
- Creates `API_SERVER_KEY` (random, never rotates existing)
- Sets `API_SERVER_PORT` (first free port from 8643-8670)
- Sets `API_SERVER_HOST=127.0.0.1` (local only)
- Starts the launchd service if not running
- Publishes the port via `tailscale serve` if Tailscale is available

## Local networking

### Ports

| Port(s)    | Service                        | Notes                              |
| ---------- | ------------------------------ | ---------------------------------- |
| 8643-8670  | Main profile gateway           | First free port in range           |
| 8642       | Bot gateways (reserved)         | Left for non-main profiles         |
| 9119       | Dashboard                      | Default dashboard port             |
| 9222       | CDP (agent browser)             | **Do not use for testing**         |
| 8080       | Vite dev server                | Web companion dev                   |
| 8091       | Playwright E2E (default)        | Override with `ALICE_E2E_PORT`     |

### Tailscale

The usual setup: the Mac and iPhone are on the same Tailscale network. The
gateway is published via `tailscale serve` as a TCP forward to `127.0.0.1`.

The pairing QR advertises the Tailscale address, not the local IP. The
gateway itself only listens on `127.0.0.1`.

### CORS (web direct mode)

When using the web companion in direct browser mode, Hermes must allow the
Alice origin via CORS. The web companion includes a diagnostic for this.

## Cron/scheduled behavior

Hermes has its own cron system (Pantheon, 0.21+). Alice exposes it through the
scheduled-job editor in the iOS app. Cron jobs are profile-scoped and managed
through the dashboard.

The Alice plugin has its own scheduled routines:
- **Morning briefing:** appointments, due/overdue reminders, goals, Mac health,
  overnight errors.
- **Evening briefing:** what was left open, with a "Remind me tomorrow" button.

These are configured through Hermes cron, not iOS background tasks.

iOS background execution is opportunistic — iOS wakes the app when it chooses.
When the phone is locked, notifications or approvals may wait until the app is
opened.

## Plugin locations

| Path                                    | Contents                              |
| --------------------------------------- | ------------------------------------- |
| `~/.hermes/plugins/alice/`              | Plugin code (installed)               |
| `~/.hermes/plugins/alice/dashboard/`    | Dashboard backend (plugin_api.py)     |
| `~/.hermes/plugins/alice/skills/`       | Plugin skills (read-only)             |
| `~/.hermes/plugins/alice/vendor/`       | Python dependencies (pypdf)           |
| `~/.hermes/backups/`                    | Plugin backups                        |
| `~/.hermes/profiles/<name>/`            | Profile data (sessions, memory, vault)|
| `~/.hermes/config.yaml`                 | Hermes configuration                  |
| `~/.hermes/hermes-agent/venv/`          | Hermes Python virtualenv              |

## Environment variables

### Web companion (`.env`)

| Variable                  | Required | Description                                      |
| ------------------------- | -------- | ------------------------------------------------ |
| `HERMES_COOKIE_SECRET`    | Prod     | Encrypts the connection cookie (long random)     |
| `DATABASE_URL`            | Prod     | Neon Postgres connection string                   |
| `BETTER_AUTH_SECRET`      | Prod     | Auth secret (min 32 chars)                        |
| `BETTER_AUTH_URL`         | Prod     | App URL for auth callbacks                        |
| `VITE_AUTH_ENABLED`       | Prod     | Must not be `false` in production                 |
| `ALICE_OWNER_EMAIL`       | Optional | Owner email for local machine access              |
| `ALICE_OWNER_CLAIM_LOCAL` | Setup    | Promotes @local.test account to owner             |
| `ALICE_OWNER_NAME`        | Optional | Owner display name                                |
| `ALICE_OWNER_PASSWORD`    | Optional | Password for email login                           |
| `GOOGLE_CLIENT_ID`        | Optional | Google OAuth client ID                             |
| `GOOGLE_CLIENT_SECRET`    | Optional | Google OAuth client secret                         |

### Hermes gateway (per-profile `.env`)

| Variable              | Description                              |
| --------------------- | ---------------------------------------- |
| `API_SERVER_KEY`      | Gateway bearer token (random)            |
| `API_SERVER_PORT`     | Gateway port (8643+)                     |
| `API_SERVER_HOST`     | Gateway bind address (127.0.0.1)         |

### Notifier

The Bark key is stored in macOS Keychain:
```bash
security add-generic-password -U -s alice-bark -a "$USER" -T /usr/bin/security -w
```

## Certificates

- **iOS signing:** Apple Developer team `2DYYWXP5XL`. Automatic signing via
  Xcode. The team ID is in `ios/project.yml`.
- **Web TLS:** Handled by Vercel (automatic).
- **Hermes gateway:** Uses `http` for local; `https` via Tailscale serve for
  remote access.
- **No custom certificates are managed by Alice.**

## Deployments

### Web companion (Vercel)

1. Push to `main` triggers Vercel deployment (if Vercel is configured).
2. Each deployment is immutable.
3. Verify: `npm run release:verify -- <url>`
4. Promote to production alias in Vercel dashboard.
5. Rollback: promote a previous deployment (do not rebuild).

### iOS app

1. `cd ios && xcodegen generate`
2. Build for device (see "Building for iPhone" below).
3. Install on iPhone.
4. Build numbers only go up (`CURRENT_PROJECT_VERSION`).
5. Verify the version on device: `xcrun devicectl device info apps`.

### Hermes plugin

1. Back up: `cp -r ~/.hermes/plugins/alice ~/.hermes/backups/plugin-alice-$(date +%Y%m%d)`
2. Install: `hermes-plugin/install.sh`
3. Restart gateway: `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway`
4. Restart dashboard: `launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard`
5. One at a time. Verify with `bash scripts/alice-doctor.sh`.

## Build/release order

When shipping a change that touches multiple surfaces:

1. **Database migrations first** (if any). Run `npm run db:migrate` against
   production. Verify old code still works.
2. **Web companion** — deploy to Vercel. Verify.
3. **Hermes plugin** — install, restart gateway then dashboard.
4. **iOS app** — build and install on device. Verify.

This order ensures each layer is compatible before the next one changes.

## Building for iPhone

On this Mac (no simulator):

```bash
cd ios && xcodegen generate
xcodebuild -project Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
```

The device ID (`A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B`) is the user's iPhone.

## Manual cleanup

### Old plugin backups

```bash
ls -t ~/.hermes/backups/plugin-alice-* | tail -n +8 | xargs rm -rf
```

### Old Vercel deployments

Managed in Vercel dashboard. Keep at least the last known-good.

### iOS build artifacts

```bash
rm -rf ios/.build/
```

### PGLite database (web dev)

Delete the local PGLite database to reset:
```bash
rm -rf node_modules/.pglite/
```

## Dependency updates

### npm

```bash
npm audit          # check for vulnerabilities
npm outdated       # check for updates
npm update         # update within semver range
```

Always use `npm ci` (not `npm install`) to reproduce the exact dependency tree.

### Swift packages

Managed in `ios/project.yml`. Update version numbers there, then regenerate:
```bash
cd ios && xcodegen generate
```

### Python (plugin)

The plugin installs `pypdf==6.18.0` into its own vendor directory. Update by
re-running `hermes-plugin/install.sh`.

### Hermes

```bash
hermes update
```

After updating Hermes:
1. Check release notes for breaking changes.
2. Update contract fixtures (`src/lib/hermes-contract-fixtures.ts`).
3. Run `npm run test:hermes:live` against a test installation.
4. Update the compatibility matrix if needed.

## Migrations

See [MIGRATIONS](MIGRATIONS.md) for the full policy. Summary:

```bash
npm run db:migrate    # apply pending migrations
```

Local PGLite migrates automatically. Production (Neon) requires the manual
command. Never edit an applied migration.

## Recovery procedures

See [DISASTER_RECOVERY](DISASTER_RECOVERY.md) for the full analysis.

Quick recovery:
- **Hermes down:** `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway`
- **Dashboard down:** `launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard`
- **Plugin broken:** Restore from `~/.hermes/backups/`, re-run install.sh
- **Web down:** Promote previous Vercel deployment
- **Data corrupted:** Restore from `scripts/backup-alice.sh` backup

## Logs

| Service    | Log location                              |
| ---------- | ------------------------------------------ |
| Gateway    | `~/.hermes/logs/` or `launchctl` logs       |
| Dashboard  | `~/.hermes/logs/` or `launchctl` logs       |
| Notifier   | `~/Library/Logs/AliceNotifier.log`          |
| Vercel     | Vercel dashboard (runtime logs)            |
| iOS        | Console.app (filter by "Alice")            |
| Web dev    | Terminal (Vite dev server output)          |

**Never log secrets, tokens, keys, or private message content.** The
operational telemetry contract rejects these fields (see
[operational-telemetry](operational-telemetry.md)).

## Troubleshooting shortcuts

| Symptom                          | First check                                    |
| -------------------------------- | ---------------------------------------------- |
| "No Alice tab in dashboard"      | Plugin not installed or dashboard not restarted |
| "Alice cannot find Hermes"       | Network/Tailscale, gateway running?            |
| "The key is not correct"         | Gateway key mismatch — re-pair or update .env  |
| "Hermes sent something unreadable"| Codable incompatibility — check [PROTOCOL](PROTOCOL.md) |
| CORS error in web                | Hermes CORS config for Alice origin            |
| Pairing QR expired               | Generate new QR (5-minute TTL)                 |
| Build fails                      | `cd ios && xcodegen generate` first            |
| npm ci fails                     | Check Node version (22.13+ or 24+)              |
| Plugin tests fail                | Use Hermes venv: `~/.hermes/hermes-agent/venv/bin/python` |
| Port conflict                    | Check `ALICE_E2E_PORT` for Playwright           |

## Development/release machine assumptions

1. **One Mac** is the development and Hermes host machine. It is an Intel Mac
   with 16 GB RAM and no iOS simulator.
2. **One iPhone** is the test device. Its UDID is
   `A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B`.
3. **Apple Developer Team:** `2DYYWXP5XL`.
4. **Tailscale** is the usual network between Mac and iPhone.
5. **Hermes 0.21.x** is the required version. The plugin is tested against
   commit `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`.
6. **CI runs on GitHub-hosted runners** (ubuntu-latest and macos-latest),
   not on the development Mac.
7. **The pre-push hook** runs Quality checks locally because CI may not start
   if Actions billing is unsettled.
8. **Build numbers only go up.** Never reset `CURRENT_PROJECT_VERSION`.
