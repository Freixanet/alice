# Alice — Testing System and Release Process

What is tested, how, and how changes reach the user. Evidence: `package.json`,
`.github/workflows/*`, `scripts/verify-ios.sh`, `docs/verification.md`,
`docs/release-operations.md`, `AGENTS.md`. **UNKNOWN** marks missing
evidence.

## Testing system

### Layers and commands

| Layer | Command | Scope and caveats |
| --- | --- | --- |
| Web unit | `npm test` (Vitest) | transports, contracts, sync, markdown, dialogs; `*.test.ts(x)` next to sources |
| Web coverage | `npm run test:coverage` | part of `check:static`; on loaded machines use `-- --maxWorkers=2` |
| Static suite | `npm run check:static` | format, lint, types, strict-contracts types, unit, coverage, cycles (madge), duplicates (jscpd), design check, iOS render-reads, slash parity, CI build, bundle smoke, bundle budgets |
| E2E | `npm run test:e2e` (Playwright) | Chromium, Firefox, WebKit; isolated local DB, **auth disabled** — does not establish registration/OAuth/recovery in production |
| E2E visual | `tests/e2e/visual.spec.ts` | committed screenshot baselines |
| E2E performance | `tests/e2e/performance.spec.ts` | p95 ≤ 100 ms for a normal Alice API handler excluding Hermes latency; INP budget accounts for measured Chromium keystroke platform cost |
| Live Hermes contract | `npm run test:hermes:live` with `HERMES_LIVE_URL`/`HERMES_LIVE_KEY` | read-only, against a dedicated test installation only |
| Hermes fixtures | `src/lib/hermes-contract-fixtures.ts` | 0.21.3 stable + 0.21.2, 0.21.0, 0.20.6 regression |
| iOS unit | `bash scripts/verify-ios.sh unit` | scheme `Alice` → `AliceTests` (137 files), "Alice Verification" simulator |
| iOS UI | `bash scripts/verify-ios.sh ui` | `AliceUITests`; cold simulator runs can take much longer than unit tests |
| iOS performance | `bash scripts/verify-ios.sh performance` (CI only; local run is disabled) | scheme `AlicePerformance`; five measured iterations per journey; summary via `scripts/ios_performance_summary.py` |
| Plugin | `~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests` | 40 files; CI installs official Hermes at commit `b889e4e…` so tests run against the same upstream the dev Mac runs |
| Notifier | `python -m unittest discover -s mac/notifier` | stdlib-only code |
| Secret scan | `gitleaks detect --source=. --no-banner --redact` | pinned 8.30.1 in CI |
| Dependency hygiene | `npm run deps:check` (knip), `npm run security:check` (audit high) | supply-chain gates |

### Testing principles (binding)

- "A clean build is not proof that a feature works against Hermes"
  (`AGENTS.md`).
- Fixture tests do not establish live model outcomes; read-only live
  contract checks must be clearly distinguished from fixture tests
  (`AGENTS.md`).
- Simulator tests cannot establish background delivery, camera behavior or
  all network conditions on a real phone; before release, review on a
  physical iPhone: fresh pairing, camera permission denial, network loss,
  suspension, long responses, attachments, keyboard navigation, large text,
  reconnect after the Hermes host restarts (`docs/verification.md`).
- Never weaken a check or update snapshots merely to turn them green
  (`AGENTS.md`).
- Use an isolated simulator and test data; never UI-test on the person's
  real iPhone (`AGENTS.md`).

### CI (`.github/workflows/`)

- `quality.yml` (PR + push to main, GitHub-hosted runners — free because
  the repo is public, and "the development Mac must not run CI"):
  `verify` job (gitleaks → Node 24/npm 11.19.0 → `check:static` →
  `security:check` → `deps:check` → build → bundle budgets → Python 3.11 +
  installed official Hermes → plugin + notifier tests), `browser` job
  (three engines e2e, report artifact on failure), `ios` job (`macos-26`,
  Xcode 26, `verify-ios.sh all`, 45-minute budget, results artifact).
- `ios-performance.yml` (manual dispatch + path-filtered): measurement
  parser unittests, offline journey measurement, metrics export and
  markdown summary.

## Release process

Alice has no store channel; releases are (1) iPhone sideloads, (2) the
Vercel web deployment, (3) the plugin copy on the Hermes Mac. Each has its
own evidence requirements.

### Before any release

- Work from `main`; record the Alice commit, Hermes version/commit,
  toolchain, commands, results, screenshots and omissions
  (`docs/verification.md` "Evidence to attach").
- Run `npm run security:check` and `npm run deps:check`
  (`docs/verification.md`).
- Check migrations and backups, production secrets and database
  configuration, signing/distribution and rollback (`docs/verification.md`).

### iPhone release

1. Build from `main` with an incremented build number:
   `CURRENT_PROJECT_VERSION` is passed to `xcodebuild` (never set in
   `project.yml`) — "the build number only goes up"
   (`AGENTS.md` Alice specifics).
2. Install via `xcrun devicectl device install app` (device id in
   `AGENTS.md`).
3. Read the version back off the device
   (`xcrun devicectl device info apps`) before saying the install arrived.
4. On the development Mac (no simulators), a successful device build is
   the local iOS check; report that simulator unit/UI tests were not run
   (`AGENTS.md` This Mac).

### Hermes plugin release (the Mac)

1. Compare the live copy `~/.hermes/plugins/alice` with the repo; **merge,
   never just overwrite**; back up to `~/.hermes/backups/plugin-alice-*`
   (`docs/HANDOFF.md`, `AGENTS.md`).
2. Deploy, then restart `ai.hermes.gateway`, and after it answers,
   `ai.hermes.dashboard` — one at a time (`AGENTS.md`).
3. Run the plugin's unittests against the Hermes venv before deploying
   (`AGENTS.md` Verification).

### Web release (Vercel)

1. Migrate the database first when needed: `npm run db:migrate` against
   the production database through the deployment environment. Migrations
   are additive and backward-compatible; "a code rollback must never
   require a destructive database rollback"
   (`docs/release-operations.md`; `migrations/0001` header).
2. Deploy to Vercel (immutable deployment URL). Every API response carries
   `X-Alice-Version` / `X-Alice-Environment`; `GET /api/status` returns
   the closed release identity with `Cache-Control: no-store`
   (`docs/release-operations.md`).
3. Verify: `npm run release:verify -- https://<production-alias>` — fails
   unless the endpoint is healthy and body and header identify the same
   version. Record that version with the immutable deployment URL before
   promoting (`docs/release-operations.md`).
4. Exercise login, `/connect`, one Hermes read and one chat request
   (`docs/release-operations.md` rollback step 4 — the same smoke set is
   the post-promotion check).

### Rollback

- **Web:** select the last known-good immutable deployment in Vercel,
  promote it to the production alias (do not rebuild), re-run the release
  verifier, exercise the smoke set, preserve failed-release logs, open a
  corrective change from `main` (`docs/release-operations.md`).
- **Encrypted sync schema:** verify creating a sync set, importing its
  recovery phrase on a second test device, and rejecting a different
  phrase before promoting (`docs/release-operations.md`).
- **iOS:** reinstall the previous build; build numbers keep rising.
- **Plugin:** restore the backup under `~/.hermes/backups/` and restart
  gateway then dashboard.

### Reporting

End every release report with three parts: **checked** (with evidence),
**not checkable here** (on this Mac: anything visual on screen, real
purchases and payments, the model's behaviour in a live conversation), and
**remaining risk** (`AGENTS.md` Alice specifics). "The user's explicit
instructions determine publication authorization" (`AGENTS.md`).
