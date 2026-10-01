# Alice — AI Agent Guide

You are an AI coding agent (or a new engineer) starting on Alice with zero
prior context. This page orients you fast and keeps you out of the traps.
It adds nothing new: it points at the rules that already exist. `AGENTS.md`
remains the authoritative shared instruction file; if this page and
`AGENTS.md` ever disagree, `AGENTS.md` wins.

## 1. Read this first (in order)

1. `README.md` — what the product is.
2. [ARCHITECTURE.md](ARCHITECTURE.md) — surfaces, contracts, history.
3. `AGENTS.md` — the binding working rules (contracts, verification,
   checklists).
4. `SECURITY.md` — threat model and where keys live.
5. The doc closest to your task:
   [SYSTEM_MAP.md](SYSTEM_MAP.md) (where things are),
   [DATA_FLOW.md](DATA_FLOW.md) (how data moves),
   [DEBUGGING.md](DEBUGGING.md) (what is broken),
   [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md) (what is fragile),
   [RELEASE.md](RELEASE.md) (how to verify and ship),
   [DEPENDENCIES.md](DEPENDENCIES.md) (what you may add),
   [OPERATIONS.md](OPERATIONS.md) (how to run everything).

## 2. What you are working on

A personal, self-hosted front end for the Hermes agent: a native iOS app
(primary), a Hermes dashboard plugin (Mac side) and a web companion.
One user, one Hermes installation. Not a SaaS. Not a Nous Research
product. iOS is the primary surface.

## 3. Start of every task

- Check `git status --short`, the branch and the base commit; preserve
  existing changes (`AGENTS.md`).
- Identify the affected surface and its tests before changing anything.
- Work on a topic branch. Make "the smallest coherent change; avoid
  unrelated formatting and speculative rewrites" (`AGENTS.md`).
- Read `docs/verification.md` and `docs/compatibility-matrix.md` before
  claiming release readiness.

## 4. Non-negotiable contracts

These come from `AGENTS.md` "Contracts that must survive changes". The full
list with reasons is in
[KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md) §"Things that MUST NOT be
casually refactored". The short version:

1. Never reroute a conversation across profiles or silently change its
   model.
2. Validate origins before attaching secrets; keep redirect protections;
   iOS secrets stay in Keychain; never log or commit secrets.
3. Old persisted archives must keep decoding; never replace an unreadable
   archive with an empty one.
4. Validate recovery keys before replacing them or uploading; save pulled
   sync records with their cursor; account changes cancel old-account work.
5. Use official, versioned Hermes contracts and detected capabilities;
   preserve unknown stream events; "unsupported ≠ empty ≠ offline ≠
   unauthorized".
6. Destructive actions name their target; never claim completion before
   the remote operation succeeds.
7. Distinguish notification kinds; never promise always-on delivery while
   the app is closed.
8. Never automatically retry a mutable Hermes action
   (`docs/request-lifecycle.md`).

## 5. Verification by surface

| Surface | Command | Notes |
| --- | --- | --- |
| iOS (unit) | `bash scripts/verify-ios.sh unit` | only on a machine with simulators (CI) |
| iOS (UI/visual) | `bash scripts/verify-ios.sh ui` + visual review | required for navigation, layout, keyboard, onboarding changes |
| iOS (this Mac) | device build via `xcodebuild … generic/platform=iOS` | the dev Mac has no simulators on purpose; report that simulator suites were not run |
| Web static | `npm run check:static` | after `npm ci` with npm 11.19.0 |
| Web e2e | `npm run test:e2e` | isolated DB, auth disabled — does not prove auth flows |
| Plugin | `python -m unittest discover -s hermes-plugin/tests` (Hermes venv, `PYTHONPATH=$HOME/.hermes/hermes-agent`) | runs against official Hermes at the pinned commit |
| Notifier | `python -m unittest discover -s mac/notifier` | — |
| Cross-surface | both transports, profile scoping, `npm run slash:check`, regenerate `Alice.xcodeproj` from `project.yml` | never commit the generated project |

Cross-surface change means: check both web transports (proxy and direct)
and keep iOS/web slash-command parity.

## 6. Hard prohibitions

- Do not create simulators, download simulator runtimes, or run
  `scripts/verify-ios.sh` on the development Mac (`AGENTS.md`).
- Do not test in the person's shared agent browser (CDP 127.0.0.1:9222);
  use a temporary Chrome on another port (`AGENTS.md`).
- Do not send prompts to, change settings on, or restart a person's real
  Hermes in routine tests (`AGENTS.md`).
- Never run UI tests on the user's real iPhone (real data)
  (`AGENTS.md`).
- Do not merge, tag, deploy or claim universal compatibility from
  incomplete evidence; "the user's explicit instructions determine
  publication authorization" (`AGENTS.md`).
- Never weaken a check, change an expectation, or update snapshots just to
  turn them green (`AGENTS.md`).
- Never commit generated Xcode projects, credentials, build outputs or
  local data (`AGENTS.md`).

## 7. Where new code goes

- New behavior belongs "in a focused service, model or feature module";
  avoid growing `AppStore.swift` and the legacy web transports
  (`AGENTS.md` "Keep the project maintainable").
- Reuse the existing design system and components; check
  `docs/design-system.md` (no gradients, no shadows, one accent at a time,
  radius 8 — `docs/plan-2026-09-20-backlog.md`).
- Adding Swift files requires `cd ios && xcodegen generate`; the generated
  project is not committed (`ios/README.md`).
- New iOS features that can break must add their own `DiagnosticCheck` to
  `all` (`docs/verification.md` Developer mode section).
- Justify every new dependency; knip fails on unlisted or unused packages
  (`AGENTS.md`, `knip.json`).

## 8. Commit and PR discipline

- Style follows the repo's existing commits: lowercase type prefixes,
  plain-language subjects describing observable behavior
  (`git log` examples: `fix(ios): /model in Alice's chat names the model
  chosen there`).
- The PR template lives at `.github/pull_request_template.md`; CONTRIBUTING
  requires the exact checks run and any limitation, screenshots for visual
  changes, and a compatibility-matrix update when Hermes support changes.
- End the report with **checked** (evidence), **not checkable here**, and
  **remaining risk** (`AGENTS.md`).
- The task checklist in `AGENTS.md` ("close every task with evidence")
  applies to every task; tick only what was actually checked.

## 9. Common traps specific to this codebase

- **A clean build is not a working feature** against Hermes
  (`AGENTS.md`).
- Multimodal chat turns must be wrapped in an explicit user message —
  `/v1/runs` misreads a bare parts array (`HermesChatStream.swift`).
- A Swift default does not make decoding old archives work
  (`AGENTS.md` Data contract).
- Plugin changes need a gateway and dashboard restart to take effect
  ([README.md](../README.md) step 1).
- The purchase flow's safety lives in the plugin (`pay_gate`, payment
  ledger, `purchase_options` validation), not in the model's good behavior
  (`errands.py`, `purchase_flow.py`, `docs/purchases.md`).
- Experimental interfaces are developer-mode gated and must stay inert when
  developer mode is off (`docs/verification.md`).
- The user writes in Spanish and expects plain explanations and a single
  recommendation (`docs/HANDOFF.md`).

## 10. If you are stuck

- [DEBUGGING.md](DEBUGGING.md) has a symptom → diagnosis table.
- [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md) lists fragile areas and
  known bugs with their evidence.
- `docs/HANDOFF.md` and `docs/plan-2026-09-20-backlog.md` record where
  work last stood (both may be stale — verify against `git log`).
- The tests are the fastest specification: `hermes-plugin/tests/`,
  `ios/AliceTests/`, `src/lib/*.test.ts`.

The question that matters most at the end: _what evidence shows this change
does what was asked and keeps what already worked?_ (`AGENTS.md`)
