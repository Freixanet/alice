# Release Process

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document consolidates the release process for all Alice components.
See also [docs/verification.md](verification.md),
[docs/release-operations.md](release-operations.md), and
[docs/compatibility-matrix.md](compatibility-matrix.md).

## Prerequisites

- All checks pass on `main` (Quality workflow green).
- Physical iPhone available for device testing.
- Hermes test installation available for live contract checks.
- Vercel deployment access (web companion).
- Neon Postgres access (web companion database).

## iOS release

### 1. Verify

```bash
# CI must pass (Quality workflow, all three jobs)
# On the development Mac, build for device:
cd ios && xcodegen generate
xcodebuild -project Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
  -allowProvisioningUpdates build
```

### 2. Physical device review

Test on a physical iPhone:
- Fresh pairing (QR scan)
- Camera permission denial
- Loss of network
- App suspension (background/foreground)
- Long responses
- Attachments
- Keyboard navigation
- Large text (Dynamic Type)
- Dark mode
- Reconnect after Hermes host restart
- iPad layout (if claiming iPad readiness)

### 3. Record evidence

Record: Alice commit, build number, Hermes version/commit, Xcode/iOS
versions, commands run, results, screenshots, and omissions.

The build number only goes up (`CURRENT_PROJECT_VERSION`). Read the version
off the device: `xcrun devicectl device info apps`.

### 4. Install

```bash
xcrun devicectl device install app --device <DEVICE-UDID> \
  ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
```

## Hermes plugin release

### 1. Back up

```bash
cp -R ~/.hermes/plugins/alice ~/.hermes/backups/plugin-alice-$(date +%Y%m%d)
```

### 2. Compare and merge

```bash
diff -r ~/.hermes/plugins/alice hermes-plugin/
# Merge changes; never just overwrite
```

### 3. Install

```bash
hermes-plugin/install.sh
```

### 4. Restart services (one at a time)

```bash
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway
# Wait for gateway to answer
launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard
```

### 5. Verify

- Check the Alice tab appears in the dashboard.
- Generate a pairing QR and verify it works.
- Run plugin tests: `~/.hermes/hermes-agent/venv/bin/python -m unittest
  discover -s hermes-plugin/tests`

## Web companion release

### 1. Verify

```bash
npm ci
npm run check:static
npm run test:e2e
npm run security:check
npm run deps:check
```

### 2. Database migration (if needed)

Database changes are additive and backward-compatible. Run migrations
before promoting:

```bash
npm run db:migrate  # against production database through deployment env
```

Do not edit an already-applied migration. Do not remove encrypted records
to make a migration pass.

For `0005_sync_verifier.sql`: verify creating a sync set, importing its
recovery phrase on a second test device, and rejecting a different phrase
before promoting.

### 3. Deploy

Deploy to Vercel. Every API response includes `X-Alice-Version` and
`X-Alice-Environment` headers.

### 4. Verify deployment

```bash
npm run release:verify -- https://alice-ten-phi.vercel.app
```

Verification fails unless the endpoint is healthy and its body and release
header identify the same version. Record that version alongside the
immutable Vercel deployment URL before promoting it.

### 5. Exercise main flows

- Login
- `/connect`
- One Hermes read
- One chat request

## Hermes contract updates

When Hermes releases a new version:

1. Read the official release notes.
2. Compare changed source contracts at the tag.
3. Update fixtures and their exact source commits in
   `src/lib/hermes-contract-fixtures.ts`.
4. Preserve older regression cases.
5. Test direct, proxy, and native behavior for changed operations and
   unknown fields.
6. Run the read-only live contract check against a dedicated test
   installation:
   ```bash
   npm run test:hermes:live  # with HERMES_LIVE_URL and HERMES_LIVE_KEY
   ```
7. Exercise real chat, approvals, cancellation, canonical sessions, and
   reconnect only in an explicitly designated test agent.

## Rollback

### Web companion

1. Select the last known-good immutable Vercel deployment.
2. Promote that deployment to the production alias; do not rebuild.
3. Run the release verifier against the production alias.
4. Confirm the version matches.
5. Exercise login, `/connect`, one Hermes read, one chat request.
6. Preserve failed release logs.
7. Open a corrective change from `main`.

Database changes are additive, so a code rollback never requires a
destructive database rollback.

### iOS

Build and install the previous version from `main` or the relevant commit.
The build number only goes up; a rollback installs a lower build number.

### Plugin

```bash
cp -R ~/.hermes/backups/plugin-alice-YYYYMMDD/. ~/.hermes/plugins/alice/
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway
launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard
```

## Evidence to attach to a release

- Alice commit SHA
- Hermes version/commit
- Toolchain versions (Xcode, Node, npm, Python)
- Commands run and results
- Screenshots
- Omissions (what could not be checked)
- Database migration status
- Backups created
- Signing/distribution status
- Rollback instructions

## What a badge is not

A Quality badge describes a workflow run. It is not a certification of
every feature. Fixture tests do not establish live behavior. A clean build
does not prove a feature works against Hermes. ([docs/verification.md](verification.md))
