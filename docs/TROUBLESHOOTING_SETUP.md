# Troubleshooting Setup

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

## Common setup issues

### Node version not supported

**Symptom:** `npm ci` fails or scripts complain about Node version.

**Cause:** Node 23 is not supported. Alice requires ^22.13 or >=24.

**Fix:**
```bash
# Install nvm if you don't have it
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash

# Install a supported Node
nvm install 24
nvm use 24

# Or Node 22
nvm install 22
nvm use 22
```

`scripts/ci-local.sh` attempts to use nvm automatically if the ambient
Node is unsupported.

---

### npm version mismatch

**Symptom:** `npm ci` warns about npm version.

**Cause:** npm 11.19.0 is pinned via `packageManager` in `package.json`.

**Fix:**
```bash
npm install -g npm@11.19.0
```

---

### XcodeGen not found

**Symptom:** `xcodegen: command not found`

**Fix:**
```bash
brew install xcodegen
```

---

### Xcode 26 not found

**Symptom:** `xcodebuild` fails or selects wrong Xcode.

**Fix:**
- Install Xcode 26 from the Mac App Store or developer.apple.com.
- If multiple Xcode versions installed:
  ```bash
  sudo xcode-select -s /Applications/Xcode_26*.app
  ```

---

### iOS 26 simulator runtime not installed

**Symptom:** `scripts/verify-ios.sh` fails with "Install an iOS 26
simulator runtime in Xcode."

**Fix:**
- Xcode → Settings → Components → install iOS 26 runtime.
- Or: `xcodebuild -downloadPlatform iOS`

**Note:** Never do this on the development Mac (Intel, 16 GB). It will make
the machine unusable. Simulator tests run in CI only.

---

### gitleaks not found

**Symptom:** `scripts/ci-local.sh` reports "gitleaks unavailable."

**Fix (option 1 — binary):**
```bash
brew install gitleaks
```

**Fix (option 2 — Docker):**
```bash
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:v8.28.0 \
  detect --source=/repo --no-banner --redact
```

---

### npm ci fails

**Symptom:** `npm ci` fails with version conflicts.

**Cause:** `package-lock.json` is out of sync with `package.json`.

**Fix:**
```bash
rm -rf node_modules package-lock.json
npm install
npm ci  # should now work
```

**Do not commit the regenerated `package-lock.json` unless you intended to
update dependencies.**

---

### Playwright browsers not installed

**Symptom:** `npm run test:e2e` fails with browser not found.

**Fix:**
```bash
npx playwright install --with-deps chromium firefox webkit
```

---

### Hermes plugin tests fail

**Symptom:** `python -m unittest discover -s hermes-plugin/tests` fails
with import errors.

**Cause:** The plugin tests require Hermes' Python venv.

**Fix:**
```bash
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
```

Or set the environment variable:
```bash
ALICE_HERMES_TEST_PYTHON=~/.hermes/hermes-agent/venv/bin/python
```

If Hermes is not installed, the plugin tests cannot run locally. They run
in CI which installs official Hermes at commit
`b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`.

---

### Hermes not found

**Symptom:** `hermes: command not found`

**Fix:** Install Hermes from the official repository:
https://github.com/NousResearch/hermes-agent

Alice requires Hermes 0.21.x.

---

### Plugin not appearing in dashboard

**Symptom:** No "Alice" tab in the Hermes dashboard.

**Cause:** Plugin not enabled or dashboard not restarted.

**Fix:**
```bash
# Install the plugin
hermes-plugin/install.sh

# If the dashboard was not restarted automatically:
launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard

# Restart any running gateway (Hermes loads plugins once per process):
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway
```

---

### Port conflict

**Symptom:** `EADDRINUSE` or port already in use.

**Cause:** Another process using the same port.

**Fix:**
```bash
# Find the process
lsof -i :8080  # or :8091, :8081

# Kill it
kill <PID>

# Or use a different port for Playwright
ALICE_E2E_PORT=8092 npm run test:e2e
```

---

### PGLite bootstrap fails

**Symptom:** Vite dev server fails with DB bootstrap error.

**Cause:** PGLite (in-browser Postgres) failed to initialize.

**Fix:**
- Clear browser storage: DevTools → Application → Storage → Clear site
  data.
- Restart the dev server.
- If the issue persists, check that migrations are valid:
  ```bash
  npm run db:migrate
  ```

---

### Vite blocks Tailscale host

**Symptom:** Vite dev server returns 403 for `.ts.net` hosts.

**Cause:** Vite 6+ blocks unknown hosts (DNS rebinding guard).

**Fix:** Vite config already includes `.ts.net` in `allowedHosts`. If it
still fails, check the exact hostname:
```bash
# In vite.config.ts, server.allowedHosts should include ".ts.net"
```

---

### iOS build fails with code signing error

**Symptom:** `xcodebuild` fails with code signing errors.

**Fix:**
- Open `ios/Alice.xcodeproj` in Xcode.
- Select the Alice target → Signing & Capabilities.
- Select your development team.
- Ensure your iPhone is connected and trusted.
- Use `-allowProvisioningUpdates` with `xcodebuild`.

---

### pre-push hook is too slow

**Symptom:** `git push` takes several minutes.

**Cause:** The pre-push hook runs `ci-local.sh verify`.

**Fix (temporary):**
```bash
SKIP_CI=1 git push
```

**Fix (permanent):** Run `npm run format:check && npm run lint` before
pushing. The hook runs the verify job which includes static checks,
security, deps, and plugin tests. If those pass locally, the hook is fast.

---

### Bundle budget exceeded

**Symptom:** `npm run bundles:check` fails.

**Cause:** A change increased the bundle size beyond the budget.

**Fix:**
- Investigate what increased: check the bundle composition.
- Reduce the size (tree-shake, lazy-load, remove unused code).
- Do not increase the budget without understanding why.

---

### Coverage floor not met

**Symptom:** `npm run test:coverage` fails with coverage below threshold.

**Cause:** A change reduced coverage below the ratcheted floor.

**Fix:**
- Add tests for the new/changed code.
- Do not lower the floor. The floors match the first v4 baseline and
  should only move upward.

---

### Type error in strict contracts

**Symptom:** `npm run typecheck:contracts` fails.

**Cause:** A new `exactOptionalPropertyTypes` violation in a strict
domain.

**Fix:**
- Omit unavailable optional values instead of emitting properties whose
  value is `undefined`.
- Add the domain to `tsconfig.strict-contracts.json` only after removing
  violations. See [docs/type-safety.md](type-safety.md).
