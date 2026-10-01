# Validation Tiers

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

Alice has a comprehensive but expensive validation system. This document
defines five proportional tiers so future coding agents stop running the
entire validation universe after trivial changes.

## How to choose a tier

1. Identify what changed (files, behavior, surface).
2. Match to a tier below.
3. Run the tier's commands.
4. Escalate if any check fails or if the change type warrants a higher tier.

**When in doubt, run one tier higher.**

## TIER 0 — seconds

**Purpose:** Very fast structural/static checks. Run before committing.

**Triggering change types:** Any change. Documentation, comments,
formatting, any code.

**Commands:**
```bash
make verify-0
```

Which runs:
```bash
npm run format:check
npm run lint
```

| Check | Tool | Expected runtime |
|-------|------|-----------------|
| Format check | Prettier | ~2s |
| Lint | ESLint (max-warnings 0) | ~5s |

**What it intentionally does NOT run:**
- Type checking (too slow for Tier 0)
- Tests
- Builds
- iOS checks
- Plugin tests
- Secret scanning (run in CI, not locally on every save)

**Escalation conditions:**
- Format or lint failure → fix before proceeding.
- New lint rule triggered → understand it before disabling.

---

## TIER 1 — small change

**Purpose:** Local confidence for narrow changes. A single function, a
bug fix, a small refactor with no behavior change.

**Triggering change types:** Single-file TypeScript change, single Swift
model change, single plugin function, no new dependencies, no new API
surface.

**Commands:**
```bash
make verify-1
```

Which runs:
```bash
npm run format:check
npm run lint
npm run typecheck
npm run typecheck:contracts
npm test -- --reporter=dot
```

| Check | Tool | Expected runtime |
|-------|------|-----------------|
| Format + Lint | Prettier + ESLint | ~7s |
| Type check | tsc --noEmit | ~10s |
| Contract types | tsc (strict-contracts) | ~5s |
| Unit tests | Vitest | ~15-30s |

**What it intentionally does NOT run:**
- E2E tests (too slow for Tier 1)
- Coverage (not needed for narrow changes)
- Build (not needed unless shipping)
- Bundle budgets
- iOS tests (require simulator)
- Plugin tests (require Hermes venv)
- Static analysis (cycles, duplicates, design system)

**Escalation conditions:**
- Type error → fix before proceeding.
- Test failure → diagnose, do not weaken the check.
- A test touches a different surface → run Tier 2.

---

## TIER 2 — feature

**Purpose:** Checks needed when behavior changes. A new feature, a changed
algorithm, a modified API contract.

**Triggering change types:** New feature, behavior change, new API
endpoint, changed parsing logic, modified state machine, changed sync
logic, changed Hermes contract.

**Commands:**
```bash
make verify-2
```

Which runs:
```bash
make verify-1
npm run test:coverage
npm run cycles:check
npm run duplicates:check
npm run design:check
npm run ios:render-check
npm run slash:check
npm run build:ci
npm run bundle:smoke
npm run bundles:check
```

| Check | Tool | Expected runtime |
|-------|------|-----------------|
| Tier 1 | (above) | ~30-60s |
| Coverage | Vitest --coverage | ~30-60s |
| Circular deps | Madge | ~5s |
| Duplicates | jscpd | ~5s |
| Design system | check-design-system.mjs | ~2s |
| iOS render reads | check-ios-render-reads.mjs | ~2s |
| Slash parity | check-slash-parity.mjs | ~2s |
| Build | Vite build (CI mode) | ~30-60s |
| Bundle smoke | smoke-server-bundle.mjs | ~5s |
| Bundle budgets | check-bundle-budgets.mjs | ~2s |

**What it intentionally does NOT run:**
- E2E tests (Tier 3)
- iOS simulator tests (Tier 3)
- Plugin tests (require Hermes venv)
- Security audit
- Dependency check

**Escalation conditions:**
- Coverage drops below ratcheted floor → fix the gap, do not lower the
  floor.
- Circular dependency detected → break the cycle.
- Bundle budget exceeded → investigate the cause.
- Build failure → fix before proceeding.

---

## TIER 3 — PR

**Purpose:** Broad integration confidence. Everything a pull request needs
before merging.

**Triggering change types:** Any PR. Cross-surface changes. Changes to
shared code. Changes to tests.

**Commands:**
```bash
make verify-3
```

Which runs:
```bash
make verify-2
npm run security:check
npm run deps:check
npm run test:e2e
```

Plus, if iOS code changed and a Mac with Xcode 26 is available:
```bash
bash scripts/verify-ios.sh unit
```

Plus, if plugin code changed and Hermes venv is available:
```bash
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s mac/notifier
```

Plus, secret scan:
```bash
gitleaks detect --source=. --no-banner --redact
```

| Check | Tool | Expected runtime |
|-------|------|-----------------|
| Tier 2 | (above) | ~2-3 min |
| Security audit | npm audit --audit-level=high | ~5s |
| Dependency check | Knip | ~10s |
| E2E tests | Playwright | ~5-10 min |
| iOS unit tests | xcodebuild | ~10-20 min (CI) |
| Plugin tests | Python unittest | ~30s |
| Secret scan | gitleaks | ~10s |

**What it intentionally does NOT run:**
- iOS UI tests (Tier 4 — they need a cold simulator and take 30+ minutes)
- iOS performance benchmarks (only when harness changes)
- Live Hermes contract tests (require dedicated test Hermes)
- Physical device testing (Tier 4)

**Escalation conditions:**
- E2E failure → investigate, do not disable the test.
- Security vulnerability → patch before proceeding.
- Unused dependency → remove it.
- Secret detected → rotate immediately.

---

## TIER 4 — release

**Purpose:** Full release validation. Everything must pass before a
release.

**Triggering change types:** Release preparation. Major version bump.
Database migration. Hermes contract update.

**Commands:**
```bash
make verify-release
```

Which runs:
```bash
make verify-3
bash scripts/verify-ios.sh all
```

Plus:
- Physical iPhone review (fresh pairing, camera denial, network loss,
  suspension, long responses, attachments, keyboard, large text, dark
  mode, reconnect).
- Web: `npm run release:verify -- https://<production-url>`
- Live Hermes contract check (if Hermes updated):
  `npm run test:hermes:live` with `HERMES_LIVE_URL` and `HERMES_LIVE_KEY`.
- Database migration (if schema changed): `npm run db:migrate`.
- Plugin deployment and restart (if plugin changed).
- Record all evidence (commit, Hermes version, toolchain, commands,
  results, screenshots, omissions).

| Check | Tool | Expected runtime |
|-------|------|-----------------|
| Tier 3 | (above) | ~10-15 min |
| iOS all tests | xcodebuild (unit + UI) | ~30-45 min (CI) |
| Physical device review | Manual | ~30 min |
| Release verify | verify-release.mjs | ~5s |
| Live contract test | Vitest (live) | ~1 min |
| Database migration | migrate.mjs | ~10s |

**What it intentionally does NOT run:**
- iOS performance benchmarks (separate workflow, only when harness changes)
- Real purchases (require real accounts and money)
- Real Hermes prompts (require dedicated test agent)

---

## Quick reference: what tier for my change?

| What changed | Tier |
|-------------|------|
| README, docs, comments | 0 |
| CSS, styling (no behavior) | 0 |
| Single TypeScript function (no behavior change) | 1 |
| Single Swift model (no Codable change) | 1 |
| Single plugin function | 1 |
| New feature (web) | 2 |
| Changed parsing logic | 2 |
| Changed state machine | 2 |
| Changed sync logic | 2 |
| Changed Hermes contract | 2 + live contract test |
| Any PR | 3 |
| Cross-surface change | 3 |
| Release | 4 |
| Database migration | 4 |
| Hermes version update | 4 |

## Relationship to existing commands

Alice already has these commands. The Makefile targets map to them:

| Make target | Existing equivalent |
|-------------|-------------------|
| `make verify-0` | `npm run format:check && npm run lint` |
| `make verify-1` | `npm run format:check && npm run lint && npm run typecheck && npm run typecheck:contracts && npm test` |
| `make verify-2` | `npm run check:static` (without E2E) |
| `make verify-3` | `npm run check` + iOS unit + plugin + gitleaks |
| `make verify-release` | `npm run check` + `verify-ios.sh all` + device review |

The Makefile does not replace existing commands — it provides proportional
entry points. `npm run check` and `bash scripts/ci-local.sh` remain valid
for running everything.
