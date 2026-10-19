# Alice — Repository Map

A directory-by-directory map of `Freixanet/alice`. Statements are traceable
to files; anything not verifiable is marked **UNKNOWN**.

## Top level

| Path | What it is | Evidence |
| --- | --- | --- |
| `README.md` | Product overview, get-started, limitations | — |
| `AGENTS.md` | Shared instructions for every coding tool (Codex, Claude Code, Cursor); contracts and verification policy | first lines of `AGENTS.md` |
| `CLAUDE.md` | Points at `AGENTS.md` | `CLAUDE.md` |
| `CONTRIBUTING.md` | Human/AI contribution rules | `CONTRIBUTING.md` |
| `SECURITY.md` | Threat model, key storage table, supply-chain checks | `SECURITY.md` |
| `LICENSE` | MIT | `LICENSE` |
| `.cursor/rules/alice.mdc` | Cursor-specific rule pointing at the shared policy | `.cursor/rules/alice.mdc` |
| `.hermes/` | A committed sample Hermes profile (`profiles/descargas/{config.yaml,SOUL.md}`) used as a fixture | `.hermes/profiles/descargas/` |
| `package.json` / `package-lock.json` | Web client manifest; npm 11.19.0 pinned via `packageManager` | `package.json` |
| `vercel.json` | Security headers (CSP, HSTS, Permissions-Policy) and `no-store` on `/api/*` | `vercel.json` |
| `vite.config.ts`, `tsconfig.json`, `tsconfig.strict-contracts.json` | Build/type config; the strict-contracts file is the `exactOptionalPropertyTypes` ratchet | `docs/type-safety.md` |
| `eslint.config.mjs`, `.prettierrc`, `.prettierignore` | Lint/format | — |
| `knip.json`, `skills-lock.json` | Dependency/unused-file check config; hash-pinned external skills (`apple-design`, `design-review`) | `knip.json`, `skills-lock.json` |
| `vitest.config.ts`, `playwright.config.ts` | Unit and e2e test config | — |
| `.gitleaks.toml`, `.githooks/pre-push` | Secret scanning config and git hook | — |
| `.env.example` | Server env vars: `HERMES_COOKIE_SECRET`, production `DATABASE_URL` / Better Auth / Google OAuth, owner claim vars | `.env.example` |

## `ios/` — native iPhone app (primary surface)

- `project.yml` — XcodeGen source of truth for the whole project; targets,
  entitlements (HealthKit read), Info.plist properties (usage descriptions,
  background modes, `alice://` URL scheme, Live Activities, ATS exceptions
  for `ts.net` and `100.64.0.0/10`).
- `README.md` — app shape, key storage, verification.
- `Alice/` — the app target: `AliceApp.swift`, `Assets.xcassets`,
  `DesignSystem/` (Theme, Haptics, AliceMark…), `Features/` (Agenda, Browser,
  Catalog, Chat, Connect, Developer, Errands, Feed, Goals, Notes, Purchase,
  Settings, Shell), `Models/` (~45 value types), `Networking/` (28 files,
  see ARCHITECTURE.md §5), `Notifications/`, `Resources/`, `Shared/`,
  `Storage/` (AppStore, KeyStore, ConversationArchive, HermesAddress…).
- `AliceActivities/` — WidgetKit extension drawing the agent Live Activity;
  shares only `AgentActivity.swift`, `BotMark.swift`, `ColorHex.swift` and
  the bot portraits (`ios/project.yml` comment).
- `AliceShare/` — share extension; hands a paragraph or URL to Alice as a
  composer draft; "does not talk to Hermes" (`ios/project.yml` comment).
- `AliceTests/` — 137 unit-test files (contract-level coverage: bot chats,
  errands, purchases, drafts, approvals…).
- `AliceUITests/`, `AlicePerformanceTests/` — UI and performance suites
  (schemes `Alice` and `AlicePerformance`).
- `scripts/` — `verify-ios.sh` runner; `check-news-feed.swift`.

## `hermes-plugin/` — the Alice plugin for Hermes (Mac side)

- `plugin.yaml` — name `alice`, `kind: standalone`, `provides_tools`
  (note_* , agent_create/rename, alice_app_status, alice_recent_errors,
  calendar_events, page_watch_*, pdf_form_*, spending_summary),
  `provides_hooks` (`pre_tool_call`, `post_tool_call`).
- `install.sh` — copies to `~/.hermes/plugins/alice`, enables it, restarts
  the macOS dashboard service when present; vendors `pypdf==6.18.0`;
  honours `HERMES_HOME`.
- `build.sh` — builds the dashboard tab bundle (`dashboard/dist/index.js`).
- `__init__.py` — hook layer: Business-team message isolation
  (`pre_tool_call` on `message_agent`), notes toolset wiring, `ui_meta`
  placements.
- `dashboard/plugin_api.py` — FastAPI router at `/api/plugins/alice/`:
  pairing session/claim, memory, notes, plus everything the tab exposes.
- `dashboard/{src/index.js, dist/index.js, manifest.json}` — the Alice tab
  in Hermes' dashboard.
- Focused modules: `agent_engine.py` (shared create/rename engine),
  `errands.py` + `purchase_flow.py` + `purchases.py` + `catalog.py` +
  `vault_cards.py` (the buying pipeline), `browser_live.py` (shared
  browser), `page_watch.py`, `goals.py`, `feed.py`, `health.py` (Mac
  CPU/memory), `memory_keeper.py` / `memory_review.py` (curated memory),
  `skill_keeper.py`, `lessons.py`, `places.py`, `calendar_snapshot.py`,
  `documents.py` (PDF forms, spending summaries), `free_web.py`,
  `ask_person.py`, `task_finish.py`, `action_log.py`, `connector_icons.py`,
  `egress_guard.py`, `secret_store.py`, `text_channel.py`,
  `vault_otp.py`, `alice_progress.py`.
- `skills/comprar/SKILL.md` — the agent-facing purchase instructions.
- `tests/` — 40 unittest files, run against official Hermes at pinned
  commit `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`
  (`.github/workflows/quality.yml`).
- `README.md` — plugin-side compatibility notes.

## `mac/notifier/` — optional Mac notifier

`alice_notifier.py` (stdlib-only, Bark push, read-only Hermes DBs),
`install.sh`, `test_alice_notifier.py`.

## `hermes-agents/` — installable agent definitions and skills

Not code Alice runs; definitions installed onto a Hermes installation:

- `alice/` — `persona.md` (applied to `~/.hermes/SOUL.md`) and
  `instalar.py`.
- `proactiva/` — the Today/briefing setup: `buenos_dias.py` (read-only
  overnight gatherer), `cierre_dia.py`, `antes_de_cita.py`, the
  `alice-proactiva.md` instructions, `instalar.py`, tests
  (`docs/proactive.md`).
- `business-team/` — the Business (Beta) channel: leader
  (`chief-of-staff.md`), ten role agents, shared templates, `instalar.py`.
- `forja/` — Agent Maker: `SOUL.md`, skill
  `forja-crear-agentes/` (SKILL.md, `scripts/crear_agente.py`, style
  guide), `install.sh`, tests with a fake Hermes CLI.
- `internet/` — the `reach` read-only web command and its skill
  (`reach.py`, SKILL.md, `instalar.py`, tests) (`docs/internet.md`).
- `evals/`, `aplicar_estilo.py`, `prueba_estilo.py` — evaluation and
  persona-style helpers.

## `src/` — web companion (React 19 + TanStack Start)

- `routes/` — file-based routes: `_app/*` pages (connect, agents, skills,
  tools, addons, cron, artifacts, insights, memory, projects, settings),
  `api/*` handlers (`chat`, `hermes`, `sync`, `status`, `telemetry`,
  `phone`, `auth-methods`, Better Auth under `auth/$`).
- `components/` — chat, cloud sync, dialogs (cron, MCP, webhooks, toolset),
  radar-ia setup, settings panel, markdown, virtual message list, `ui/`
  primitives.
- `lib/` — the client's real logic. Notable clusters:
  - Hermes transports: `gateway.ts` / `gateway.server.ts` (proxy),
    `hermes-direct.ts` (browser), `hermes-transport.ts`,
    `hermes-live.ts` (per-operation transport resolution),
    `hermes-live.server.ts`, `hermes-live-parse.ts`.
  - Contracts: `gateway-contracts.ts`, `hermes-contract-fixtures.ts`,
    `hermes-contract-verifier.ts`, `api-contracts.ts`,
    `conversation-contracts.ts`.
  - Encrypted sync: `sync-*` (client, contracts, crypto, device-key, merge,
    replica, runtime, store), backed by `migrations/0003` + `0005`.
  - Auth: `auth/` (Better Auth server/client, owner gate, isolation,
    session boundary, Google OAuth, email-password).
  - Ops: `db.ts` (PGlite/Postgres via Kysely), `csp.ts`,
    `deployment-config.ts`, `hermes-operations.ts` (mutation schemas),
    `store.ts` (zustand), `i18n.ts`.
- `start.ts`, `router.tsx`, `routeTree.gen.ts`, `styles.css`.

## `migrations/` — web database schema (source of truth)

`0001_auth.sql` (Better Auth tables, camelCase, DO NOT EDIT),
`0002_hermes_gate.sql` (sealed per-user Hermes credentials),
`0003_encrypted_sync.sql` (E2EE sync records),
`0004_security_hardening.sql` (cross-instance rate limiting),
`0005_sync_verifier.sql` (adds `verifier` record kind). Applied by
`npm run db:migrate` to Neon in production and automatically to local
PGLite; recorded in `_migrations`, never re-run (`0001` header comment).

## `mcp-servers/cobalt-mcp/` — media download MCP server

`server.mjs`, `lib.mjs` (+ `lib.test.mjs` run with `node --test`); emits the
`alice://file` media line as `media_markdown:`
(`docs/hermes-contracts.md`).

## `cobalt/` — `docker-compose.yml` for the cobalt service used by
cobalt-mcp. Scope beyond the compose file: **UNKNOWN**.

## `scripts/` — build, check and ops tooling

`with-app-env.mjs` (env-wrapped dev/build), `phone.mjs` (Tailscale
exposure), `migrate.mjs` (db migrations), `verify-ios.sh` (simulator
verification), `verify-release.mjs`, `check-design-system.mjs`,
`check-slash-parity.mjs` (iOS/web slash-command parity), 
`check-ios-render-reads.mjs`, `check-bundle-budgets.mjs`,
`smoke-server-bundle.mjs`, `browser-guard.mjs`, `app-env-plugin.mjs`,
`pwa-plugin.mjs` / `pwa-shared.mjs`, `write-atomic.mjs`,
`ios_performance_summary.py` (+ tests), `ci-local.sh`, `migration-plan.mjs`,
`sign-out-plan.mjs`.

## `tests/` — Playwright e2e

`app.spec.ts` (functional), `visual.spec.ts` (+ committed screenshots),
`performance.spec.ts` (p95 API budget, Web Vitals), `radar-ia.spec.ts`,
`fixtures/hermes-empty/` (empty-Hermes fixture).

## `.github/` — CI

- `workflows/quality.yml` — on PR and push to `main`: gitleaks 8.30.1,
  Node 24 + npm 11.19.0, `check:static`, `security:check`, `deps:check`,
  build + bundle budgets, plugin and notifier tests against installed
  official Hermes (Python 3.11, commit `b889e4e…`); a `browser` job
  (Chromium/Firefox/WebKit e2e) and an `ios` job (`macos-26`,
  `scripts/verify-ios.sh all`, 45-minute budget).
- `workflows/ios-performance.yml` — manual + path-filtered performance
  baseline on `macos-26`.
- `ISSUE_TEMPLATE/`, `pull_request_template.md`.

## `docs/` — documentation

Product and protocol docs referenced throughout this manual:
`pairing.md` (ES), `hermes-contracts.md`, `request-lifecycle.md`,
`verification.md`, `compatibility-matrix.md`, `release-operations.md`,
`operational-telemetry.md`, `type-safety.md`, `chat-virtualization.md`,
`design-system.md`, `purchases.md` (ES), `proactive.md`, `internet.md`
(ES), `radar-ia.md`, `getting-connected.md` (ES user guide), `HANDOFF.md`,
`quality-audit-2026-09-25.md`, `plan-2026-09-20-backlog.md` (ES), plus this
manual set. `media/` holds images used by README and docs.

## Generated / local artifacts (never committed)

`ios/Alice.xcodeproj`, `ios/.build/`, `.vercel/`, `node_modules/`,
local databases — per `ios/.gitignore`, `AGENTS.md` ("never commit
generated Xcode projects, credentials, build outputs or local data").
