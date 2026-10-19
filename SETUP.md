# Setup

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`
>
> This guide assumes your current Mac disappears tomorrow. It makes Alice
> reproducibly buildable/developable from a clean compatible Mac using
> only this repository, explicitly documented external credentials, and
> supported toolchains.

## Prerequisites

### Required (all surfaces)

| Tool | Version | How to install |
|------|---------|---------------|
| macOS | 15+ (Sequoia) | — |
| Xcode | 26 | Mac App Store or developer.apple.com |
| XcodeGen | latest | `brew install xcodegen` |
| Node.js | ^22.13 or >=24 | nvm or brew |
| npm | 11.19.0 | bundled with Node, or `npm install -g npm@11.19.0` |
| Python | 3.11 | brew or system |
| Git | any recent | brew or system |
| gitleaks | 8.30.1 | `brew install gitleaks` |

### Required (iOS only)

| Tool | Version | How to install |
|------|---------|---------------|
| iOS 26 SDK | 26.0 | Xcode → Settings → Components |
| Apple Developer account | any | developer.apple.com |

### Required (web only)

| Tool | Version | How to install |
|------|---------|---------------|
| Playwright browsers | 1.62.x | `npx playwright install --with-deps chromium firefox webkit` |

### Required (Hermes plugin only)

| Tool | Version | How to install |
|------|---------|---------------|
| Hermes agent | 0.21.x | See Hermes documentation |
| Hermes Python venv | matches Hermes | Installed with Hermes |

### Optional

| Tool | Purpose |
|------|---------|
| Tailscale | Network connectivity between iPhone and Mac |
| Docker | Fallback for gitleaks if binary unavailable |
| nvm | Node version management |

## Quick start

```bash
# 1. Clone
git clone https://github.com/Freixanet/alice.git
cd alice

# 2. Bootstrap (checks prerequisites, installs deps)
./bootstrap

# 3. Start web development server
npm run dev

# 4. Build iOS app (requires Xcode + XcodeGen)
cd ios && xcodegen generate && open Alice.xcodeproj
```

## External credentials (never committed)

### iOS

- Apple Developer team ID (for code signing)
- Device UDID (for device installation)

### Web (production)

| Variable | Purpose | Required for |
|----------|---------|--------------|
| `HERMES_COOKIE_SECRET` | Encrypts connection cookie | Production |
| `DATABASE_URL` | Neon Postgres connection | Production |
| `BETTER_AUTH_URL` | Auth callback URL | Production |
| `BETTER_AUTH_SECRET` | Auth session signing | Production |
| `VITE_AUTH_ENABLED` | Enable web auth | Production |
| `ALICE_OWNER_EMAIL` | Owner identity | Production |
| `GOOGLE_CLIENT_ID` | Google OAuth | Optional |
| `GOOGLE_CLIENT_SECRET` | Google OAuth | Optional |

Copy `.env.example` to `.env` and fill in values. Never commit `.env`.

### Hermes plugin

- Hermes must be installed and running on the Mac.
- The plugin installs to `~/.hermes/plugins/alice/`.
- pypdf is vendored automatically by `install.sh`.

## What the bootstrap script does

1. Checks Node.js version (≥22.13 or ≥24)
2. Checks npm version (≥11.0.0)
3. Checks Python version (3.11)
4. Checks for XcodeGen (if iOS development)
5. Checks for gitleaks (if secret scanning)
6. Runs `npm ci` (installs web dependencies)
7. Verifies the installation with `npm run format:check`

The script fails clearly if any prerequisite is missing. It does not
install system-level tools (Xcode, Homebrew) — those require manual
installation.

See [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) for the full environment
audit and [docs/TROUBLESHOOTING_SETUP.md](docs/TROUBLESHOOTING_SETUP.md)
for common issues.
