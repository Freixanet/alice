# Architecture

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 Oct 2026)
>
> This document supersedes the prior `docs/architecture.md`. Every claim is
> traceable to code, configuration, Git history, tests, or existing
> documentation in this repository. Uncertainty is marked **UNKNOWN**.

## 1. What Alice is and is not

### What Alice is

Alice is a native iPhone app that serves as the mobile companion for a user's
self-hosted [Hermes agent](https://hermes-agent.nousresearch.com). It brings
together conversation, live agent work, approval requests, secure credential
entry, and agent management on iOS.

Alice also contains:

- a **Hermes plugin** (Python) that adds pairing, memory, notes, agent
  creation, and browser sharing to a Hermes installation;
- a **web companion** (React 19 / TanStack Start) that provides browser access
  to the same Hermes, with account boundaries and encrypted conversation sync;
- a **Mac notifier** (Python) for optional local notifications;
- **Hermes agents** (Python + Markdown) defining Alice's persona, routines, and
  evals;
- an **MCP server** (cobalt-mcp, Node.js) that emits `alice://file` media marks.

### What Alice is not

- **Not a hosted service.** It needs a Hermes the user runs and a model
  provider the user pays for. ([README.md](../README.md))
- **Not on the App Store.** It requires Xcode and an Apple developer account.
  ([README.md](../README.md))
- **Not a cloud VM or independent network security boundary.** The Mac running
  Hermes is the user's own machine. ([docs/quality-audit-2026-09-25.md](quality-audit-2026-09-25.md))
- **Not a fork of Hermes.** Everything Alice needs from the server lives in a
  Hermes plugin using public hooks. ([README.md](../README.md))
- **Not a replacement for Hermes' safety.** Alice adds checks on top and never
  removes any. ([AGENTS.md](../AGENTS.md))
- **Not WhatsApp-compatible.** ([README.md](../README.md))

## 2. Product principles discoverable from the implementation

These principles are inferred from code, tests, Git history, and
documentation — not imposed.

1. **The phone never becomes the server.** No push infrastructure, no cloud of
   our own. The iPhone talks to Hermes over the user's network. Background
   delivery is best-effort, as iOS allows. ([README.md](../README.md))
2. **Official Hermes, no fork.** The plugin uses Hermes' public hooks (`tools`,
   `pre_tool_call`, `post_tool_call`, `transform_llm_output`). Updating Hermes
   does not overwrite Alice. ([hermes-plugin/plugin.yaml](../hermes-plugin/plugin.yaml))
3. **Hermes' own safety stays in charge.** Cards and logins go into Hermes'
   vault. Payments pass Hermes' confirmation. Alice adds checks and never
   removes any. ([AGENTS.md](../AGENTS.md))
4. **Deterministic where it can be.** Health patterns use plain statistics (≥14
   days, correlation ≥0.4). Card formats use Luhn. The model is used for
   judgement, not arithmetic. ([README.md](../README.md))
5. **iOS first.** The native app is the primary surface; the web is a
   companion. ([docs/architecture.md](architecture.md), [AGENTS.md](../AGENTS.md))
6. **Secure sheets instead of pasting secrets.** Logins, codes, API keys, and
   payment cards go straight to Hermes' vault, never into chat. ([README.md](../README.md))
7. **Approvals that say what they approve.** Hermes' approval requests become
   cards in chat, not raw commands. ([README.md](../README.md))
8. **Smallest correct change.** AGENTS.md mandates the smallest coherent
   change, no unrelated formatting, no speculative rewrites. ([AGENTS.md](../AGENTS.md))
9. **Never claim completion before the remote operation succeeds.**
   ([AGENTS.md](../AGENTS.md))
10. **Preserve backward compatibility of stored data.** Read old Codable
    archives before extending persisted models. ([AGENTS.md](../AGENTS.md))

## 3. Complete system architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        iPhone (Alice)                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────────┐   │
│  │ SwiftUI  │  │Networking│  │ Storage  │  │ Notifications │   │
│  │ Features │←→│HermesCli │←→│AppStore  │  │ PlaceWatcher   │   │
│  │  Chat    │  │ HermesRPC│  │KeyStore  │  │ EventDigest    │   │
│  │  Browser │  │ Stream   │  │Archive   │  │ LiveActivity   │   │
│  │  Agenda  │  │ Pairing  │  │          │  │                │   │
│  └──────────┘  └────┬─────┘  └──────────┘  └───────────────┘   │
│                   │ Keychain (WhenUnlockedThisDeviceOnly)        │
└───────────────────┼─────────────────────────────────────────────┘
                    │ HTTPS / WSS (Tailscale or LAN)
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Mac / Server (Hermes)                          │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────┐    │
│  │ Hermes       │  │ Hermes       │  │  Alice Plugin        │    │
│  │ Gateway      │  │ Dashboard    │  │  (Python, FastAPI)   │    │
│  │ (API server) │  │ (management) │  │  - Pairing QR        │    │
│  │ /v1/*        │  │ /api/*       │  │  - Memory/Notes      │    │
│  │ JSON-RPC     │  │              │  │  - Agent Engine      │    │
│  │ WebSocket    │  │              │  │  - Egress Guard      │    │
│  └──────┬───────┘  └──────┬───────┘  │  - Browser Live      │    │
│         │                 │          │  - Vault Cards       │    │
│         │                 └──────────┤  - Purchases         │    │
│         │                            │  - Page Watch        │    │
│         │                            └──────────────────────┘    │
│  ┌──────┴──────────────────────────────────────────────────┐    │
│  │  Model Provider (OpenRouter, Anthropic, OpenAI, etc.)    │    │
│  │  Browser (Chromium, CDP)  │  Vault  │  Filesystem         │    │
│  └──────────────────────────────────────────────────────────┘    │
│  ┌──────────────┐                                               │
│  │ Mac Notifier │  (optional, launchd)                          │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
                    │ HTTPS (Vercel + Neon)
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Web Companion (Vercel)                         │
│  React 19 / TanStack Start / TypeScript                          │
│  - Auth (Better Auth: email/password, Google OAuth)              │
│  - Hermes proxy (encrypted httpOnly cookie)                      │
│  - Direct browser transport (sessionStorage + encrypted cookie)  │
│  - Encrypted conversation sync (E2EE, account-scoped)            │
│  - PGLite (dev) / Neon Postgres (prod)                           │
│  - Rate limiting, CSP, HSTS                                       │
└─────────────────────────────────────────────────────────────────┘
```

### Component inventory

| Component | Language | Entry point | Role |
|-----------|----------|-------------|------|
| iOS app | Swift 6.0 | `ios/Alice/AliceApp.swift` | Primary product surface |
| Hermes plugin | Python 3.11 | `hermes-plugin/dashboard/plugin_api.py` | Pairing, memory, notes, agent engine, egress guard |
| Web companion | TypeScript | `src/routes/__root.tsx` | Browser access, accounts, encrypted sync |
| Mac notifier | Python | `mac/notifier/alice_notifier.py` | Optional local notifications |
| Hermes agents | Python + Markdown | `hermes-agents/alice/persona.md` | Persona, routines, evals |
| Cobalt MCP | Node.js | `mcp-servers/cobalt-mcp/server.mjs` | Emits `alice://file` media marks |
| Migrations | SQL | `migrations/0001_auth.sql`…`0005` | Database schema |

## 4. Repository map

```
alice/
├── ios/                        # Native iOS app (SwiftUI, iOS 26)
│   ├── Alice/                   # App source
│   │   ├── AliceApp.swift       # @main entry
│   │   ├── DesignSystem/        # Theme, haptics, press styles, glass
│   │   ├── Features/            # Chat, Browser, Catalog, Agenda, etc.
│   │   ├── Models/              # Domain models (Chat, Errand, Goal, etc.)
│   │   ├── Networking/          # HermesClient, HermesRPC, streaming
│   │   ├── Notifications/       # EventDigest, Notifier, PlaceWatcher
│   │   ├── Shared/              # AgentActivity, PlainWords, StallSampler
│   │   └── Storage/             # AppStore, ConversationArchive, KeyStore
│   ├── AliceActivities/         # Live Activity widget extension
│   ├── AliceShare/              # Share extension
│   ├── AliceTests/              # ~200 unit test files
│   ├── AliceUITests/            # UI test journeys
│   ├── AlicePerformanceTests/   # Performance benchmarks
│   └── project.yml              # XcodeGen project specification
├── hermes-plugin/              # Hermes plugin (Python)
│   ├── dashboard/               # Dashboard tab (FastAPI router)
│   │   ├── plugin_api.py        # Pairing, memory, notes API
│   │   └── host_load.py         # Mac health metrics
│   ├── *.py                     # Tools and hooks
│   ├── tests/                   # Python unit tests
│   ├── skills/                  # Plugin skills (read-only)
│   └── plugin.yaml              # Plugin manifest
├── hermes-agents/              # Agent definitions (Python + Markdown)
│   ├── alice/                   # Alice persona
│   ├── business-team/           # Business team isolation
│   ├── forja/                   # Agent Maker
│   ├── internet/                # Reach (web access tools)
│   ├── proactiva/               # Routines (morning, evening, appointments)
│   └── evals/                   # Evaluation harness
├── src/                        # Web companion (React 19, TanStack Start)
│   ├── routes/                  # File-based routes (chat, agents, etc.)
│   ├── components/              # UI components
│   ├── lib/                     # Hermes client, sync, auth, etc.
│   └── lib/auth/                # Better Auth integration
├── mac/notifier/               # Mac notifications (Python)
├── mcp-servers/cobalt-mcp/     # Cobalt MCP server (Node.js)
├── migrations/                 # SQL migrations (0001–0005)
├── scripts/                    # Build, verify, CI scripts
├── tests/                      # Playwright E2E tests
├── docs/                       # Documentation
├── cobalt/                     # Docker compose for Cobalt
├── .github/workflows/          # CI (quality.yml, ios-performance.yml)
├── .githooks/                  # Pre-push hook
├── AGENTS.md                   # Shared AI agent instructions
├── CLAUDE.md                   # Claude Code pointer
├── CONTRIBUTING.md             # Contribution guidelines
├── SECURITY.md                 # Security model
└── package.json                # Node.js project (web companion)
```

## 5. iOS architecture

### Structure

The iOS app follows a feature-based architecture with a central observable
store:

- **`AppStore.swift`** — `@MainActor @Observable` singleton holding all UI
  state: conversations, connection, models, preferences, bot roster. Views
  read from it and actions flow through it. ([ios/Alice/Storage/AppStore.swift](../ios/Alice/Storage/AppStore.swift))
- **Features** — each feature is a self-contained directory under
  `Features/` (Chat, Browser, Catalog, Agenda, Notes, Goals, Feed, Errands,
  Purchase, Settings, Shell, Developer, Connect).
- **Models** — plain `Codable` structs in `Models/` representing domain
  entities (Conversation, Errand, Goal, Receipt, etc.).
- **Networking** — `HermesClient` (actor) for HTTP, `HermesRPC` for JSON-RPC
  over WebSocket, streaming via `HermesChatStream`. ([ios/Alice/Networking/HermesClient.swift](../ios/Alice/Networking/HermesClient.swift))
- **Storage** — `ConversationArchive` (per-chat UserDefaults records),
  `KeyStore` (Keychain), `AppStore` (observable state). ([ios/Alice/Storage/ConversationArchive.swift](../ios/Alice/Storage/ConversationArchive.swift))
- **Notifications** — `EventDigest`, `Notifier`, `PlaceWatcher`,
  `LiveEvents`, `NotificationRouting`. ([ios/Alice/Notifications/](../ios/Alice/Notifications/))

### Targets

The XcodeGen project (`ios/project.yml`) defines:

| Target | Type | Bundle ID | Role |
|--------|------|-----------|------|
| Alice | application | com.freixanet.alice | Main app |
| AliceActivities | app-extension | com.freixanet.alice.activities | Live Activity widget |
| AliceShare | app-extension | com.freixanet.alice.share | Share extension |
| AliceTests | bundle.unit-test | com.freixanet.alice.tests | Unit tests |
| AliceUITests | bundle.ui-testing | com.freixanet.alice.uitests | UI tests |
| AlicePerformanceTests | bundle.ui-testing | com.freixanet.alice.performance-tests | Performance benchmarks |

### Swift concurrency

- `SWIFT_STRICT_CONCURRENCY: complete` — Swift 6 strict concurrency enabled.
- `AppStore` is `@MainActor @Observable`.
- `HermesClient` is an `actor`.
- `JSONObject` and `HermesRPCEvent` are `@unchecked Sendable`.
- `HermesRPCTransport` is a `protocol` for testability.

### Entitlements and permissions

- HealthKit (read-only daily summaries)
- Calendar/Reminders full access
- Location (when in use + always for region monitoring)
- Camera, Microphone, Speech Recognition, Face ID
- Local network (NSAllowsLocalNetworking + Tailscale exception)
- Background fetch (`com.freixanet.alice.refresh`)
- Live Activities

## 6. Mac / backend architecture

The Mac runs Hermes (the agent runtime) with the Alice plugin. The plugin is a
Python FastAPI router mounted at `/api/plugins/alice/` inside Hermes'
dashboard.

### Hermes gateway vs dashboard

- **Gateway** — the agent API server (`/v1/*`, JSON-RPC over WebSocket). Has
  its own API key and port. May be separate from the dashboard.
- **Dashboard** — management UI and API (`/api/*`). Has its own login
  (username/password or token auth). Runs on its own port (typically 9119).

### Plugin components

| Module | File | Role |
|--------|------|------|
| Plugin API | `dashboard/plugin_api.py` | Pairing, memory, notes, agent engine endpoints |
| Agent engine | `agent_engine.py` | Create/rename Hermes profiles via CLI |
| Egress guard | `egress_guard.py` | Tainted-session egress approval |
| Memory keeper | `memory_keeper.py` | Self-maintaining curated memory |
| Memory review | `memory_review.py` | Extract durable facts from conversations |
| Browser live | `browser_live.py` | Shared Chromium browser view |
| Vault cards | `vault_cards.py` | Payment card storage in Hermes vault |
| Purchases | `purchases.py`, `purchase_flow.py` | Purchase flow and errand checkout |
| Errands | `errands.py` | Errand lifecycle management |
| Secret store | `secret_store.py` | API key storage in .env |
| Page watch | `page_watch.py` | Changedetection.io integration |
| Health | `health.py` | Mac health metrics |
| Feed | `feed.py` | Editorial feed backend |
| Goals | `goals.py` | Goal management |
| Places | `places.py` | Place trigger management |
| Calendar | `calendar_snapshot.py` | Calendar snapshot |
| Lessons | `lessons.py` | Learning from corrections |
| Skill keeper | `skill_keeper.py` | Skill safety review |
| Text channel | `text_channel.py` | Telegram/iMessage channels |
| Connector icons | `connector_icons.py` | MCP connector logos |
| Host load | `dashboard/host_load.py` | CPU/memory metrics |

### Mac notifier

`mac/notifier/alice_notifier.py` — optional Python script that sends local
macOS notifications from Hermes activity. Installed via
`mac/notifier/install.sh` as a launchd agent.

## 7. Hermes integration

Alice integrates with Hermes through two channels:

1. **Gateway API** — the iPhone talks directly to the Hermes gateway
   (`/v1/chat`, `/v1/models`, `/v1/capabilities`, JSON-RPC WebSocket for
   streaming). The gateway key is stored in iOS Keychain.
2. **Dashboard API** — the iPhone also connects to the Hermes dashboard
   (`/api/*`) for management operations: profiles, sessions, cron, MCP, etc.
   Dashboard credentials (username/password) stored in Keychain.

The **Alice plugin** extends Hermes' dashboard with pairing, memory, notes,
agent creation, and browser sharing — all through Hermes' public plugin API
(hooks and tools). It does not modify Hermes' code. ([hermes-plugin/plugin.yaml](../hermes-plugin/plugin.yaml))

### Contract versioning

Alice tracks Hermes API contracts through versioned fixtures:
- Current stable: `0.21.3` (14 Sep 2026)
- Regression fixtures: `0.21.2`, `0.21.0`, `0.20.6`
- Source contracts checked against official Hermes commits
  `v2026.9.14` and `v2026.9.11`
- CI installs official Hermes at commit
  `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c` for plugin tests
  ([.github/workflows/quality.yml](../.github/workflows/quality.yml))

([docs/hermes-contracts.md](hermes-contracts.md))

## 8. iPhone ↔ Mac communication

### Transports

| Transport | Direction | Protocol | Auth |
|-----------|-----------|----------|------|
| Gateway (HTTP) | iPhone → Mac | HTTPS (or HTTP on Tailscale) | API key (bearer) |
| Gateway (WebSocket) | iPhone → Mac | WSS (or WS on Tailscale) | API key (bearer) |
| Dashboard (HTTP) | iPhone → Mac | HTTPS | Username/password |
| Pairing | Mac → iPhone | QR code (`alice://pair`) | One-time bearer token |

### Network topology

- **Same network** — iPhone and Mac on the same LAN.
- **Tailscale** — iPhone and Mac on the same tailnet. MagicDNS names end in
  `.ts.net`; direct Tailscale IPv4 addresses are in `100.64.0.0/10`. Both
  need narrow HTTP ATS exceptions. ([ios/project.yml](../ios/project.yml))
- **Public HTTPS** — supported but requires HTTPS for the gateway address.

### Pairing protocol (v1)

1. Dashboard shows a QR containing `alice://pair?v=1&p=<base64url(json)>`.
2. The payload contains: exchange URL (`c`), one-time token (`t`), expiry
   (`e`), profile name (`pr`).
3. iPhone POSTs `{token, device_name}` to the exchange URL with
   `Authorization: Bearer <t>`.
4. Response delivers gateway `{url, key}` and dashboard
   `{url, username, password}|null`.
5. iPhone validates: same host as exchange, no URL-embedded credentials,
   HTTPS does not degrade to HTTP. No redirects.
6. Credentials saved to Keychain via `AppStore.connect` /
   `AppStore.connectDashboard`.

([docs/pairing.md](pairing.md))

## 9. Data flows

### Chat flow (iOS → Hermes)

```
User types → Composer → AppStore.send()
  → HermesClient.chat() or HermesRPC.call("chat.run")
  → WebSocket stream of events
  → HermesChatStream parses deltas
  → AppStore.conversations updated (per-chat)
  → SwiftUI views re-render
  → ConversationArchive persists (per-chat UserDefaults)
```

### Streaming and event resume

- Events carry `seq` numbers. A missed stretch can be requested via
  `session.events.since`. ([ios/Alice/Networking/EventResume.swift](../ios/Alice/Networking/EventResume.swift))
- Reconnect resumes from the last seen `seq`. ([ios/Alice/Networking/HermesChatStream.swift](../ios/Alice/Networking/HermesChatStream.swift))

### Approval flow

```
Hermes sends server→client request (srq-…) → HermesRPCEvent
  → GatewayServerRequests handles it
  → AppStore surfaces approval card in chat
  → User approves/denies
  → HermesRPC.respond(toServerRequest:result:)
```

### Secure credential flow

```
Agent needs a secret → ends reply with [Dar clave](alice://connect/secret/NAME)
  → iPhone shows SecretKeyCard
  → User enters value in secure field
  → POST /api/plugins/alice/secret → secret_store.py
  → Writes NAME=value to .env files (0600)
  → Chat only learns it was saved
```

### Purchase flow

```
Agent clarifies product → purchase_options tool → iOS shows options
  → User picks → errand_start in plugin (not at model's discretion)
  → Agent fills basket, address, delivery
  → Checkout summary → approval card (exact total)
  → User taps "Pay" → vault.fill with saved card
  → Payment outcome: confirmed / declined / failed
  → Ledger prevents duplicate payment until outcome known
```

([docs/purchases.md](purchases.md))

### Background refresh

```
iOS wakes app (BGTaskScheduler, opportunistic)
  → AppStore.backgroundRefresh()
  → Probe gateway connectivity
  → Fetch pending events (approvals, questions)
  → Local notification if needed
  → EventDigest routes by type
```

### Web sync flow

```
Client encrypts conversation (device key + recovery key)
  → POST /api/sync (ciphertext + metadata)
  → Server stores alice_sync_record (immutable)
  → Other devices pull by revision cursor
  → Client decrypts with device key
  → Hybrid storage: IndexedDB (local) + server (encrypted)
```

([docs/request-lifecycle.md](request-lifecycle.md))

## 10. Sources of truth

| Data | Source of truth | Location | Notes |
|------|----------------|----------|-------|
| Connection credentials | iOS Keychain | `KeyStore.swift` | `WhenUnlockedThisDeviceOnly` |
| Conversations (iOS) | Per-chat UserDefaults | `ConversationArchive.swift` | Old blob → split migration |
| App preferences | UserDefaults | `AppStore.swift` | Theme, accent, model, drafts |
| Hermes state | Hermes gateway/dashboard | `HermesClient.swift` | Authoritative for agent state |
| Curated memory | Hermes filesystem | `MEMORY.md` / `USER.md` | Plugin tracks origins |
| Notes | Inbox store | `workspace/inbox-store` | Append-only via `inbox.py` |
| Web accounts | Neon Postgres | `user`, `session`, `account` | Better Auth schema |
| Encrypted sync | Neon Postgres | `alice_sync_record` | E2EE, immutable verifier |
| Rate limits | Neon Postgres | `alice_rate_limit` | Per scope + pseudonymous identity |
| Hermes connection (web) | Neon Postgres | `hermes_gate` | Sealed token per user |
| Plugin state | Mac filesystem | `~/.hermes/plugins/alice/` | In-memory offers, JSON state |

## 11. State management

### iOS

- **`AppStore`** — single `@MainActor @Observable` object. All views read
  from it. Actions flow through it. ([ios/Alice/Storage/AppStore.swift](../ios/Alice/Storage/AppStore.swift))
- **`activeConversation`** — separated from `conversations` array so a view
  reading one chat doesn't depend on every chat's state.
- **`HermesClient`** — actor-isolated network client. Owns the gateway
  endpoint and key.
- **`ConversationArchive`** — prepares writes off the main thread. Only
  chats that changed are encoded. Fingerprints prevent redundant rewrites.
- **Bot chats** — each bot carries its own profile and canonical session.
  Navigating between chats must not retarget an in-flight turn.

### Web

- **Zustand** — client state management (`zustand` v5).
- **Hybrid storage** — IndexedDB (local) + server (encrypted). Cache
  separated by account.
- **Read caches** — 30-second TTL for model reads. Shared per
  account/connection/profile. Failed reads never cached.
- **Mutations** — never auto-retried. Idempotency keys where supported.

([docs/request-lifecycle.md](request-lifecycle.md))

## 12. Persistence

### iOS

- **Keychain** — gateway key, dashboard credentials. Class:
  `WhenUnlockedThisDeviceOnly`. ([ios/Alice/Storage/KeyStore.swift](../ios/Alice/Storage/KeyStore.swift))
- **UserDefaults** — conversations (per-chat keys), preferences, drafts.
  ([ios/Alice/Storage/ConversationArchive.swift](../ios/Alice/Storage/ConversationArchive.swift))
- **Codable migrations** — old single-array blob still read on launch, then
  rewritten in split form. Unreadable bytes retained for recovery.
  A Swift property default does NOT make synthesized decoding
  backward-compatible. ([AGENTS.md](../AGENTS.md))
- **Diagnostics log** — `DiagnosticsLog` records ids, states, timings (never
  message text).

### Web

- **PGLite** (dev) — local Postgres in-browser via WASM.
- **Neon Postgres** (prod) — serverless Postgres.
- **Migrations** — SQL files in `migrations/`, applied by
  `scripts/migrate.mjs`. Applied files recorded in `_migrations` table,
  never run again. Additive and backward-compatible.
- **Encrypted sync** — E2EE conversation replicas. Device key + recovery key.
  Immutable verifier. Pull cursor saved with state.

([docs/release-operations.md](release-operations.md))

## 13. Networking

### iOS networking

- **`HermesClient`** (actor) — HTTP requests to gateway (`/v1/models`,
  `/v1/capabilities`, `/v1/chat`).
- **`HermesRPC`** — JSON-RPC over WebSocket. Protocol-based
  (`HermesRPCTransport`) for testability. Server→client requests
  (approvals, questions) arrive as events.
- **`HermesChatStream`** — parses streaming deltas into typed states.
- **`DashboardClient`** — dashboard HTTP API.
- **`GatewayServerRequests`** — handles server→client RPC requests.
- **`EventResume`** — resumes missed events by `seq` number.
- **`HermesAddress`** — gateway URL validation policy. Public addresses
  require HTTPS. Local network + Tailscale allowed with ATS exceptions.

### Web networking

- **`hermes-transport.ts`** — base transport abstraction.
- **`hermes-direct.ts`** — direct browser-to-Hermes transport.
- **`gateway.server.ts`** — server proxy (encrypted httpOnly cookie).
- **`hermes-live.ts`** — WebSocket streaming client.
- **`http.server.ts`** — outbound HTTP with redirect protection.
- **`outbound-http.server.ts`** — server-side HTTP boundary.

### Security boundaries

- No redirects on credential-bearing requests.
- Same-host validation on pairing exchange.
- Gateway key never in `localStorage` or logs.
- CSP: `default-src 'self'`, no `frame-ancestors` except self.
- HSTS: `max-age=63072000; includeSubDomains; preload`.

([SECURITY.md](../SECURITY.md))

## 14. Streaming

### iOS streaming

- WebSocket JSON-RPC with event frames (`{"method":"event","params":{...}}`).
- Each event has a `seq` number for resume capability.
- `HermesChatStream` parses deltas into: `streaming`, `text_delta`,
  `tool_call`, `tool_result`, `subagent.start`, `subagent.complete`,
  `question`, `approval`, `error`, `done`.
- Unknown event types are preserved safely (`HermesUnknownEvents`).
- Reconnect resumes from last `seq` via `session.events.since`.

### Web streaming

- `hermes-live.ts` — WebSocket client for streaming events.
- `hermes-live-parse.ts` — event parser.
- `hermes-live-cache.ts` — live data cache.
- `chat-stream.ts` — chat stream state machine.
- `message-patch.ts` — incremental message patching.

## 15. Background execution

### iOS

- **BGTaskScheduler** — `com.freixanet.alice.refresh` identifier. Opportunistic
  background fetch. iOS decides when/if it runs. ([ios/project.yml](../ios/project.yml))
- **Place triggers** — iOS region monitoring for location-based reminders.
  Only arrival/departure events sent to Hermes, never the location.
- **Live Activities** — `AgentLiveActivity` shows agent work on Lock Screen
  and Dynamic Island. Updated only while Alice runs (no APNs).
- **Notifications** — local notifications for agent answers, routine
  deliveries, failures, approvals. iOS background execution is opportunistic;
  do not promise always-on delivery while the app is closed.

### Mac

- **Hermes gateway** — launchd service (`ai.hermes.gateway`).
- **Hermes dashboard** — launchd service (`ai.hermes.dashboard`).
- **Mac notifier** — optional launchd agent.
- Plugin restarts: gateway first, then dashboard, one at a time.

## 16. Authentication and security boundaries

### iOS

| Boundary | Mechanism | Scope |
|----------|-----------|-------|
| Gateway key | Keychain (`WhenUnlockedThisDeviceOnly`) | App only, when unlocked |
| Dashboard credentials | Keychain | Username + password |
| App lock | Face ID / passcode | `AppLock.swift`, `Biometrics.swift` |
| Locked notes | Face ID / passcode | Per-note encryption |

### Web

| Boundary | Mechanism | Scope |
|----------|-----------|-------|
| Account | Better Auth (email/password, Google OAuth) | `user`, `session`, `account` tables |
| Hermes connection (proxy) | Encrypted httpOnly cookie | Server decrypts key to contact Hermes |
| Hermes connection (direct) | `sessionStorage` + encrypted cookie | Browser gets key to contact Hermes directly |
| Encrypted sync | E2EE (device key + recovery key) | Conversation replicas in `alice_sync_record` |
| Rate limiting | Per scope + pseudonymous identity | `alice_rate_limit` table |
| Local access | Owner-only | `ALICE_OWNER_EMAIL`, verified account |

### Hermes plugin

| Boundary | Mechanism | Scope |
|----------|-----------|-------|
| Pairing | One-time bearer token, TTL 5 min, same-host | Loopback + Tailscale only |
| Memory | Dashboard login | Per-profile MEMORY.md/USER.md |
| Secret store | `secret_store.py` → .env (0600) | Refuses HERMES_*, API_SERVER_* names |
| Egress guard | Tainted-session approval | Terminal/code commands that send data out or read secrets |
| Business team | `pre_tool_call` hook on `message_agent` | Channel-scoped messaging isolation |
| Vault cards | Payment cards in Hermes vault | Bound to specific page |

([SECURITY.md](../SECURITY.md), [docs/pairing.md](pairing.md))

## 17. External dependencies

See [docs/DEPENDENCIES.md](DEPENDENCIES.md) for the complete dependency
inventory.

### iOS

- No third-party Swift packages. Pure SwiftUI + Foundation + HealthKit.
- Font: Instrument Serif (bundled).

### Web (npm)

- React 19, TanStack Start/Router, TypeScript 5.7, Vite 8
- Tailwind CSS 4, Radix UI, Lucide icons
- Better Auth, Kysely, PGLite, pg
- Zod, Zustand, Undici, jose
- Dev: Vitest 4, Playwright, ESLint 9, Prettier, Knip, Madge, jscpd

### Hermes plugin (Python)

- Hermes agent (official, pinned commit in CI)
- pypdf 6.18.0 (PDF forms, vendored)
- qrcode (dashboard tab, one-time install)

### Mac notifier (Python)

- Standard library + macOS notification APIs

### MCP server (Node.js)

- Cobalt MCP (in-tree)

## 18. Build system

### iOS

- **XcodeGen** generates `Alice.xcodeproj` from `ios/project.yml`.
- Swift 6.0, iOS 26 deployment target, strict concurrency.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`
- `CODE_SIGN_STYLE: Automatic`, team `2DYYWXP5XL`
- Build: `cd ios && xcodegen generate && xcodebuild ...`
- Never commit the generated `.xcodeproj`.

### Web

- **Vite 8** with TanStack Start plugin, Nitro (Vercel preset for build).
- Node ≥22.13 or ≥24, npm 11.19.0 (pinned).
- `npm ci` for reproducible installs.
- PGLite bootstrap plugin ensures DB is ready in dev.

### Plugin

- `hermes-plugin/build.sh` bundles the dashboard tab.
- `hermes-plugin/install.sh` copies to `~/.hermes/plugins/alice/`.

### CI

- **Quality workflow** (`.github/workflows/quality.yml`): gitleaks, web
  static checks, security/deps checks, build, bundle budgets, plugin tests,
  notifier tests, Playwright E2E, iOS simulator tests.
- **iOS Performance** (`.github/workflows/ios-performance.yml`): isolated
  performance benchmarks.
- **Pre-push hook** (`.githooks/pre-push`): runs `ci-local.sh verify`.

## 19. Testing system

### iOS tests

| Suite | Type | Count (approx) | What it proves |
|-------|------|----------------|----------------|
| AliceTests | Unit | ~200 files | Contracts, parsing, state, persistence |
| AliceUITests | UI | ~10 files | Navigation, keyboard, visual review |
| AlicePerformanceTests | Performance | 1 file | Launch, scroll, navigation benchmarks |

- Run: `bash scripts/verify-ios.sh [unit|ui|all|build|performance]`
- Dedicated simulator "Alice Verification" (never the developer's personal
  simulator).
- The development Mac (Intel, 16 GB) has no simulator runtimes — simulator
  tests run in CI only.

### Web tests

| Suite | Tool | What it proves |
|-------|------|----------------|
| Unit/contract | Vitest | Parsing, state, sync, crypto |
| E2E | Playwright | Browser journeys (isolated DB, auth disabled) |
| Live contract | Vitest (HERMES_LIVE_REQUIRED) | Read-only checks against test Hermes |

### Plugin tests

| Suite | Tool | What it proves |
|-------|------|----------------|
| Plugin | Python unittest | Tools, hooks, API, agent engine |
| Notifier | Python unittest | Notification logic |

### Static checks

| Check | Command | What it catches |
|-------|---------|----------------|
| Format | `npm run format:check` | Prettier violations |
| Lint | `npm run lint` | ESLint (zero warnings) |
| Types | `npm run typecheck` | TypeScript strict |
| Contract types | `npm run typecheck:contracts` | `exactOptionalPropertyTypes` |
| Coverage | `npm run test:coverage` | V8 coverage (ratcheted floors) |
| Cycles | `npm run cycles:check` | Circular dependencies |
| Duplicates | `npm run duplicates:check` | Copy-pasted code |
| Design system | `npm run design:check` | Design token compliance |
| iOS render reads | `npm run ios:render-check` | Render-thread safety |
| Bundle budgets | `npm run bundles:check` | Bundle size limits |
| Bundle smoke | `npm run bundle:smoke` | Server bundle integrity |
| Slash parity | `npm run slash:check` | Slash command parity iOS/web |
| Security | `npm run security:check` | npm audit (high+) |
| Deps | `npm run deps:check` | Knip (unused/unlisted) |
| Secret scan | gitleaks | Credential leaks |
| Feed parser | `swiftc ... check-news-feed.swift` | RSS parsing, ranking |

([docs/verification.md](verification.md))

## 20. Release process

See [docs/RELEASE.md](RELEASE.md) for the complete release process.

Summary:

1. All checks pass on `main`.
2. Physical iPhone review (fresh pairing, camera denial, network loss,
   suspension, long responses, keyboard, large text, reconnect).
3. Web: `npm run release:verify` against the production URL.
4. Record commit, Hermes version, toolchain, commands, results, omissions.
5. Database changes are additive and backward-compatible.
6. Rollback: promote previous Vercel deployment, verify with release checker.

## 21. Known fragile areas

1. **`AppStore.swift`** — large coordinator. New behavior should prefer focused
   modules. ([AGENTS.md](../AGENTS.md))
2. **Legacy web transports** — need the same restraint as AppStore.
3. **Codable backward compatibility** — a Swift property default does not
   make synthesized decoding backward-compatible. Old archives must be read
   before extending models. ([AGENTS.md](../AGENTS.md))
4. **Conversation identity** — navigating between chats must not retarget
   in-flight turns. Drafts follow conversation identity across navigation.
5. **Pairing token** — in-memory only. Restarting the dashboard invalidates
   the QR. ([docs/pairing.md](pairing.md))
6. **Plugin installation** — Hermes loads plugins once per process. Gateway
   must be restarted after plugin updates.
7. **Background delivery** — iOS controls when background refresh runs. No
   always-on guarantee.
8. **Purchase flow** — real purchases have exposed bugs. Not reliable enough
   to leave unattended. ([README.md](../README.md))
9. **Card payment (Redsys)** — Hermes finds card fields by English names and
   autocomplete tokens. Spanish bank pages may lack both.
   ([docs/HANDOFF.md](HANDOFF.md))
10. **Live browser** — slideshow (JPEG frames over long-polling), not video.
    ([docs/HANDOFF.md](HANDOFF.md))

## 22. Common failure modes

See [docs/KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md) for the complete
catalog.

## 23. How to diagnose each failure

See [docs/DEBUGGING.md](DEBUGGING.md) for diagnostic procedures.

## 24. Things that MUST NOT be casually refactored

1. **`AppStore.swift`** — central coordinator. Extract only with regression
   coverage. ([AGENTS.md](../AGENTS.md))
2. **`ConversationArchive`** — Codable migration logic. Old blob → split
   migration. Unreadable bytes retained for recovery.
3. **`HermesAddress`** — gateway URL validation policy. ATS exceptions for
   Tailscale.
4. **`HermesRPC` protocol** — testability seam. The fake transport records
   method calls.
5. **Pairing protocol** — security-critical. Token TTL, same-host validation,
   no redirects.
6. **Egress guard** — tainted-session logic. Regex patterns for egress and
   secrets.
7. **Business team isolation hook** — `pre_tool_call` on `message_agent`.
8. **Agent engine** — `agent_engine.py`. Uses official Hermes CLI. No silent
   model fallback. No partial profile deletion.
9. **Sync crypto** — device key derivation, encryption, merge logic.
10. **Type-safety ratchet** — `tsconfig.strict-contracts.json`. Domains added
    only after violations removed.

## 25. Historical architectural decisions

### Why a Hermes plugin instead of a fork

Hermes updates would collide with Alice changes if Alice forked Hermes. The
plugin uses public hooks (`tools`, `pre_tool_call`, `post_tool_call`,
`transform_llm_output`) and lives outside Hermes' code. Updating Hermes does
not overwrite Alice. ([README.md](../README.md), [hermes-plugin/plugin.yaml](../hermes-plugin/plugin.yaml))

### Why per-chat UserDefaults instead of Core Data

Conversations are stored under individual UserDefaults keys. This replaced a
single-array blob that re-encoded every conversation on every streaming delta.
The split form only encodes chats that actually changed. An old blob is still
read on launch and rewritten in split form. ([ios/Alice/Storage/ConversationArchive.swift](../ios/Alice/Storage/ConversationArchive.swift))

### Why the phone never becomes the server

No push infrastructure and no cloud of our own. The iPhone talks to Hermes
over the user's network. This avoids APNs dependency, cloud hosting costs,
and a central point of failure. Background delivery is best-effort.
([README.md](../README.md))

### Why pairing uses a QR instead of manual entry

Manual configuration requires understanding addresses, ports, and keys. The
QR replaces this with: Dashboard shows QR → iPhone scans → configured with
the main profile. The token is one-time, short-lived (5 min), and
same-host-restricted. ([docs/pairing.md](pairing.md))

### Why the egress guard exists

Meta's Muse keeps part of the trust decision below the model. Alice runs on
the user's Mac with their permissions, so the egress guard is the same idea
at the tool layer: after reading outside content, a command that could send
data out or read secrets needs the person's approval. Deterministic and cheap.
([hermes-plugin/egress_guard.py](../hermes-plugin/egress_guard.py))

### Why the type-safety ratchet exists

The initial global audit found 131 `exactOptionalPropertyTypes` violations.
The ratchet removes violations domain by domain, adding domains to the strict
config only after their violations are removed. This keeps each increment
reviewable while preventing regressions in hardened boundaries.
([docs/type-safety.md](type-safety.md))

### Why there is no WhatsApp support

WhatsApp's official agent API is not public. Alice does not use unofficial
WhatsApp Web clients. ([README.md](../README.md))

### Why the development Mac has no simulator

Booting a simulator made the Intel Mac (16 GB) unusable. Simulator tests run
in CI only. Device builds use `generic/platform=iOS`. ([AGENTS.md](../AGENTS.md))

### Why the pre-push hook exists

The Quality workflow could not start while GitHub Actions billing was
unsettled. The pre-push hook runs `ci-local.sh verify` locally — the `verify`
job that was actually catching things. A hook that takes ten minutes is a
hook people skip, so it runs only the fast checks. (`.githooks/pre-push`)
