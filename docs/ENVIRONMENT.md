# Environment

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

## Requirements by category

### AUTOMATICALLY INSTALLABLE

These can be installed by `./bootstrap` or `npm ci`:

| Requirement | How | Notes |
|-------------|-----|-------|
| npm dependencies | `npm ci` | Pinned versions in package-lock.json |
| Playwright browsers | `npx playwright install` | For E2E tests |
| pypdf (plugin) | `hermes-plugin/install.sh` | Vendored to `hermes-plugin/vendor/` |
| Dashboard tab bundle | `hermes-plugin/build.sh` | One-time `qrcode` install |
| Git hooks | `npm run prepare` | Sets `core.hooksPath` to `.githooks` |

### AUTOMATICALLY VALIDATABLE

These can be checked by the bootstrap script:

| Requirement | How to check | Minimum version |
|-------------|-------------|-----------------|
| Node.js | `node -v` | ^22.13.0 or >=24.0.0 |
| npm | `npm -v` | >=11.0.0 (pinned 11.19.0) |
| Python | `python3 --version` | 3.11 |
| XcodeGen | `xcodegen --version` | latest |
| Xcode | `xcodebuild -version` | 26 |
| gitleaks | `gitleaks version` | 8.30.1 |
| Git | `git --version` | any recent |

### MANUAL BUT DOCUMENTABLE

These require manual installation or configuration:

| Requirement | How | Notes |
|-------------|-----|-------|
| Xcode 26 | Mac App Store | ~10 GB download |
| Apple Developer account | developer.apple.com | For code signing |
| iOS 26 SDK/runtime | Xcode → Settings → Components | For simulator tests |
| Hermes agent | See Hermes documentation | 0.21.x required |
| Tailscale | tailscale.com | For iPhone ↔ Mac connectivity |
| Homebrew | brew.sh | For installing gitleaks, xcodegen |

### SECRET / MUST NEVER BE COMMITTED

| Secret | Where it lives | How to set it |
|--------|---------------|---------------|
| Gateway API key | iOS Keychain | Via pairing or manual entry |
| Dashboard credentials | iOS Keychain | Via pairing or manual entry |
| `HERMES_COOKIE_SECRET` | Server `.env` | Generate random value |
| `DATABASE_URL` | Server `.env` | Neon Postgres connection string |
| `BETTER_AUTH_SECRET` | Server `.env` | Generate random value |
| `GOOGLE_CLIENT_ID/SECRET` | Server `.env` | Google Cloud Console |
| `ALICE_OWNER_PASSWORD` | Server `.env` | Min 8 characters |
| `HERMES_LIVE_URL/KEY` | Environment only | For live contract tests |
| Pairing token | In-memory only | 5-minute TTL, one-time |

Never commit `.env`, `.env.*`, credentials, API keys, or pairing tokens.
Gitleaks scans the full history on every push.

## Environment variables reference

### Development

| Variable | Default | Purpose |
|----------|---------|---------|
| `ALICE_SIMULATOR_ID` | (auto-detected) | Override iOS simulator |
| `ALICE_DERIVED_DATA_PATH` | `ios/.build/DerivedData` | Override Xcode build path |
| `ALICE_E2E_PORT` | 8091 | Override Playwright port |
| `ALICE_HERMES_TEST_PYTHON` | `~/.hermes/hermes-agent/venv/bin/python` | Override plugin test Python |
| `SKIP_CI` | (unset) | Skip pre-push hook |
| `GITHUB_ACTIONS` | (unset) | Set by GitHub Actions |
| `GITHUB_RUN_NUMBER` | (unset) | Used for build number |
| `GITHUB_SHA` | (unset) | Used for source revision |

### Production (web)

See [SETUP.md](../SETUP.md) for the production variable list.

## Hidden environmental assumptions

### Local filesystem assumptions

| Path | Purpose | Assumption |
|------|---------|-----------|
| `~/.hermes/` | Hermes installation | Hermes installed |
| `~/.hermes/plugins/alice/` | Alice plugin | Installed via `install.sh` |
| `~/.hermes/hermes-agent/venv/` | Hermes Python venv | For plugin tests |
| `~/.hermes/backups/` | Plugin backups | Created before deploy |
| `~/.alice/hermes-credential.key` | Dev encryption key | Optional, dev only |
| `~/.nvm/` | nvm | Optional, for Node version |

### Ports

| Port | Service | Notes |
|------|---------|-------|
| 8080 | Vite dev server | `0.0.0.0:8080` |
| 8081 | Vite preview | `127.0.0.1:8081` |
| 8091 | Playwright E2E | Override with `ALICE_E2E_PORT` |
| 8643–8669 | Hermes gateway (main profile) | Provisioned by pairing |
| 9119 | Hermes dashboard | Typical |
| 9222 | Shared agent browser (CDP) | NEVER test here |

### Daemons / launch agents

| Service | Identifier | Purpose |
|---------|-----------|---------|
| Hermes gateway | `ai.hermes.gateway` | Agent API server |
| Hermes dashboard | `ai.hermes.dashboard` | Management UI |
| Mac notifier | (optional) | Local notifications |

### Simulator assumptions

- The development Mac (Intel, 16 GB) has **no iOS simulator runtimes** — on
  purpose. Do not create simulators or download runtimes.
- CI uses a dedicated "Alice Verification" simulator on `macos-26`.
- Never use a developer's personal simulator (may contain real credentials).

### Xcode/Swift version assumptions

- Xcode 26 required.
- Swift 6.0 with strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`).
- `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`.
- iOS 26.0 deployment target.
- Code signing: Automatic, team `2DYYWXP5XL`.

### Hermes setup assumptions

- Hermes 0.21.x must be installed and running.
- The plugin is loaded once per process — restart gateway and dashboard
  after updates.
- Plugin tests require the Hermes venv Python.
- CI installs official Hermes at commit
  `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`.

### Mac backend setup assumptions

- Hermes gateway listens on `127.0.0.1` (local only).
- Tailscale Serve forwards the port to the tailnet.
- The shared browser uses Chromium with CDP (never on port 9222).

### Web client setup assumptions

- PGLite (in-browser Postgres) for development — no external database
  needed.
- Neon Postgres for production.
- Vite dev server on `0.0.0.0:8080` (accessible from network).
- Tailscale MagicDNS names (`.ts.net`) need Vite `allowedHosts` exception.
- Vite 6+ blocks unknown hosts unless listed.

### Build outputs (never committed)

| Path | Generated by |
|------|-------------|
| `ios/Alice.xcodeproj` | XcodeGen from `project.yml` |
| `ios/build/`, `ios/.build/` | xcodebuild |
| `node_modules/` | npm |
| `dist/`, `.output/` | Vite build |
| `coverage/` | Vitest |
| `playwright-report/`, `test-results/` | Playwright |
| `hermes-plugin/vendor/` | pip install |
| `hermes-plugin/dashboard/dist/` | build.sh (committed) |
| `.vercel/` | Vercel CLI |

## Node version management

The shell that pushes Alice may expose Node 23, which is not supported.
`scripts/ci-local.sh` handles this by preferring an already-installed nvm
Node when the ambient one is outside the engine range. It never downloads
from a hook or silently blesses an unsupported runtime.

```bash
# Check if your Node is supported
node -e "const v=process.versions.node;const[m,n]=v.split('.').map(Number);process.exit((m>=24||(m==22&&n>=13))?0:1)"
```
