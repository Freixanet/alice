# Alice — Engineering Architecture

This is the survival manual for Alice, written so an engineer or AI coding
agent with zero prior context can change the system safely. Every claim below
is traceable to a file in the repository. Where evidence is incomplete the
text says **UNKNOWN**. It replaces and extends the former
`docs/architecture.md` (case-only rename; the content of that file is folded
into sections 6–9 below).

Companion documents, each covering its area in depth:

- [SYSTEM_MAP.md](SYSTEM_MAP.md) — what lives where in the repository.
- [DATA_FLOW.md](DATA_FLOW.md) — data flows, sources of truth, state,
  persistence, streaming, background execution.
- [OPERATIONS.md](OPERATIONS.md) — building, running and deploying.
- [DEBUGGING.md](DEBUGGING.md) — how to diagnose failures.
- [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md) — fragile areas and what
  must not be casually refactored.
- [DEPENDENCIES.md](DEPENDENCIES.md) — every external dependency.
- [RELEASE.md](RELEASE.md) — testing system and release process.
- [AI_AGENT_GUIDE.md](AI_AGENT_GUIDE.md) — the same rules, oriented for
  AI coding agents.

Older deep-dives that remain authoritative for their topics:
[request lifecycle](request-lifecycle.md), [Hermes contracts](hermes-contracts.md),
[pairing](pairing.md), [verification](verification.md),
[compatibility matrix](compatibility-matrix.md).

## 1. What Alice is

Alice is a personal, self-hosted front end for the
[Hermes](https://hermes-agent.nousresearch.com) open agent. Its primary
surface is a native iPhone app; a web client and a Hermes dashboard plugin
are companion surfaces ([README.md](../README.md), `AGENTS.md`).

- **iOS app** (`ios/`): native SwiftUI client, iOS 26, Swift 6, talks
  directly to the user's own Hermes — no Alice server sits in the middle
  (`ios/README.md`, `ios/Alice/Networking/HermesClient.swift`).
- **Hermes plugin** (`hermes-plugin/`): a standalone plugin installed into
  `~/.hermes/plugins/alice` that adds the pairing QR, curated-memory and
  notes access, the shared agent-creation engine, errands/purchases, the
  live shared browser and more (`hermes-plugin/plugin.yaml`,
  `hermes-plugin/install.sh`).
- **Web client** (`src/`): React 19 / TanStack Start companion with accounts,
  an authenticated server proxy and optional end-to-end encrypted conversation
  sync (`package.json`, `src/routes/`).
- **Mac notifier** (`mac/notifier/`): optional local process that reads
  Hermes' databases read-only and pushes "an agent answered" notifications
  through Bark (`mac/notifier/alice_notifier.py`).

Hermes and the model API keys stay on the user's own Mac or server; Alice
does not install Hermes, provide a model, or proxy the iPhone's chat
([README.md](../README.md) "You need").

## 2. What Alice is not

- **Not a Nous Research product.** "It is an independent project, not a Nous
  Research product" ([README.md](../README.md) status note).
- **Not on the App Store.** Built with Xcode onto your own iPhone
  ([README.md](../README.md)).
- **Not a hosted service for the iOS app.** The phone connects straight to
  the user's Hermes over the LAN or Tailscale (`ios/README.md`,
  `scripts/phone.mjs`). The web client's Vercel deployment is a separate,
  optional companion surface.
- **Not a fork of Hermes.** The plugin "adds … No commands or changes to
  Hermes' own code, so Hermes updates never collide with it"
  (`hermes-plugin/plugin.yaml`, `hermes-plugin/dashboard/plugin_api.py`
  module docstring).
- **Not a push-notification service.** There is no APNs integration; iOS
  background execution is opportunistic (`AGENTS.md` "Notifications"
  contract, `mac/notifier/alice_notifier.py` docstring).
- **Not an autonomous purchasing guarantee.** The purchase flow stops at the
  person's explicit "Pay"; "It is not a guarantee of purchase automation"
  (`docs/purchases.md`, `hermes-plugin/purchase_flow.py` docstring).
- **Not multi-tenant.** One person, one installation, one Hermes. The web
  client has accounts but "only the configured, verified owner" may use
  local-machine access (`SECURITY.md`, `src/lib/auth/owner.server.ts`).

## 3. Product principles

These recur across `README.md`, `AGENTS.md`, `SECURITY.md` and
`CONTRIBUTING.md`:

1. **Your own agent, your own machine.** Keys, logins and secrets stay with
   Hermes on the Mac; the chat never sees them
   (`README.md` "Why it exists", `SECURITY.md` threat model).
2. **The person decides irreversible steps.** A payment waits for one
   explicit "Pay"; approvals name their exact target (`AGENTS.md` "User
   experience" contract; `hermes-plugin/errands.py` `pay_gate`).
3. **iOS first.** The native app is the primary product; the web client is
   a companion (`docs/compatibility-matrix.md`, `AGENTS.md` first line).
4. **Honest evidence.** "Do not treat a clean build as proof that a feature
   works against Hermes" (`AGENTS.md`). Reports distinguish checked,
   not-checkable, and remaining risk.
5. **Preserve what already works.** Keep contracts and existing behaviour
   unless a change was asked for (`AGENTS.md`, `CONTRIBUTING.md`).
6. **Data survives upgrades.** Old archives must keep decoding; unreadable
   bytes are kept for recovery, never replaced with an empty archive
   (`AGENTS.md` "Data" contract; `ios/Alice/Storage/ConversationArchive.swift`).
7. **Local/private network by default.** The internet reaches Alice through
   Hermes on the Mac, not through Alice's own infrastructure
   (`docs/internet.md`, `docs/architecture` section on internet access,
   now section 9).

## 4. System architecture

Four surfaces and one supporting repo layout:

| Surface          | Responsibility                                                      | Entry points                                                        |
| ---------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------- |
| iOS — primary     | Native conversations, agent work and configuration                   | `ios/Alice/AliceApp.swift`, `Features/`, `Networking/`, `Storage/`   |
| Hermes plugin     | Pairing QR, curated memory, notes, agents, errands, browser, health | `hermes-plugin/dashboard/plugin_api.py`, `hermes-plugin/__init__.py` |
| Web — companion   | Browser access, account boundaries, encrypted conversation sync    | `src/routes/`, `src/components/`, `src/lib/`                        |
| Mac notifier      | Optional local notifications from Hermes activity                   | `mac/notifier/alice_notifier.py`                                    |

The native app connects **directly** to services on the user's Hermes host:

- The **gateway** provides the agent API (HTTP + SSE, key-authenticated).
- The **dashboard** provides management and canonical profile/session
  operations (HTTP + JSON-RPC WebSocket, username/password).
- They may have different ports and credentials
  (`docs/architecture.md` former "Connection and identity"; now this file,
  section 7; `ios/Alice/Storage/AppStore.swift` keeps `gatewayURL` and
  `dashboardURL` apart for exactly this reason).
- Pairing exchanges a short-lived code for both connections
  (`docs/pairing.md`, `hermes-plugin/dashboard/plugin_api.py`).

The web supports an authenticated server proxy and a direct browser
transport, with "operation semantics and profile scoping equivalent"
(`src/lib/hermes-live.ts` `runHermesOperation`, `src/lib/gateway.server.ts`,
`src/lib/hermes-direct.ts`).

## 5. iOS architecture

- **Language/runtime:** Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`,
  warnings-as-errors (`ios/project.yml` settings).
- **State:** one `@MainActor @Observable` `AppStore` is "everything the
  interface reads" (`ios/Alice/Storage/AppStore.swift`). Views are otherwise
  free of state juggling. `AppStore` is a known-large coordinator; new
  behavior belongs in focused modules instead (`AGENTS.md` "Keep the project
  maintainable").
- **Navigation:** chat is the app; history and surfaces live in a drawer
  (`ios/README.md` "Shape"). Features are grouped under
  `ios/Alice/Features/`: Agenda, Browser, Catalog, Chat, Connect, Developer,
  Errands, Feed, Goals, Notes, Purchase, Settings, Shell.
- **Targets** (`ios/project.yml`): `Alice` (app), `AliceActivities`
  (WidgetKit Live Activity extension), `AliceShare` (share extension that
  hands a paragraph or URL to the composer; "does not talk to Hermes"),
  `AliceTests` (unit, 137 files), `AliceUITests`, `AlicePerformanceTests`.
- **Project generation:** `Alice.xcodeproj` is generated by XcodeGen from
  `ios/project.yml` and never committed (`ios/README.md`).
- **Design:** iOS 26 Liquid Glass (`ios/README.md`) over the repo's design
  tokens (`docs/design-system.md`); the iOS render-reads check
  (`scripts/check-ios-render-reads.mjs`) keeps views reading facts, not
  doing their own state work.
- **Notable subsystems** (all under `ios/Alice/`):
  - `Networking/` — `HermesClient` (gateway HTTP/SSE), `HermesRPC` +
    `WebSocketBotChatSource` (dashboard JSON-RPC WebSocket),
    `HomeChatSession` / `BotChatSession` / `AgentTaskSession` (conversation
    identity contracts), `GatewayServerRequests` (Hermes' server→client
    questions/approvals), `EventResume`, `RoutineCatalog`,
    `HermesManagement`, `HermesUpdate`/`HermesSelfUpdate`.
  - `Storage/` — `AppStore`, `KeyStore` (Keychain), `ConversationArchive` /
    `ConversationStorage`, `HermesAddress` (gateway address policy),
    `AppLock`/`Biometrics`, `CalendarSync`, `HealthSync`, `HitchMonitor`,
    `DiagnosticsLog`.
  - `Notifications/` — `Notifier`, `NotificationRouting`, `PlaceWatcher`
    (region monitoring), `LiveEvents`, `AgentActivities`.
  - `Models/` — value types for everything the UI renders (Chat, Errand,
    PurchaseOptions, SecureRequest, TaskPlan, …).
- **Performance discipline:** the `ActiveChat`/`shownConversation` split in
  `AppStore` exists so a view reading the on-screen chat does not depend on
  the whole `conversations` array (comment in `AppStore.swift`); the
  experimental Home menu and the chat virtualization invariants are tested
  (`docs/verification.md`, `docs/chat-virtualization.md`).

## 6. Connection and identity contracts (iOS)

- The **home conversation** belongs to the default installation profile.
  Pairing always targets the profile `profiles.list` marks `is_default`
  (`docs/pairing.md` section 0).
- A **bot/agent conversation** retains its own profile and canonical
  session; navigating to another chat must not retarget an in-flight turn
  (`AGENTS.md` "Connection identity" contract; `HomeChatSession.swift`,
  `BotChatSession.swift`, `HermesRPC.swift`, `GatewayServerRequests.swift`).
- The canonical Bot Chat runs over the dashboard's JSON-RPC WebSocket with
  a `profile`, so a turn runs as that bot with its own SOUL, memory and
  skills — replacing the old gateway path where "every bot chat ran on the
  default profile wearing a synthetic 'you are <bot>' directive"
  (`WebSocketBotChatSource.swift` docstring).
- **New Agent** opens a separate conversation with the Agent Maker profile;
  `AgentTaskSession` uses profile-scoped `session.create`/`session.resume`,
  retains the durable session before submission, and a lost creation
  response is recovered by a unique UUID title. A missing saved session
  fails rather than silently redirecting or replaying work
  (`ios/Alice/Networking/AgentTaskSession.swift`; contract inspected in
  official Hermes checkout `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`,
  `tui_gateway/methods_session.py`).
- **Agent Maker** is identified by `ui_meta.alice.role = agent-maker` with a
  legacy fallback to profile `forja`; Alice mints profiles from a sentence
  (`AgentDraft`) through `hermes-plugin/agent_engine.py`, which validates a
  spec and drives the official Hermes CLI (`profile create`/`rename`).
  `reuse_profile` requires the same `job_id` that created the profile;
  a foreign profile is left intact. Alice will not start a Hermes directory
  rename (sessions keep `registry_home` on the old path and Hermes has no
  coordination outside that directory). The operations journal is rewritten
  to the status actually returned — "a client `busy` flag is not enough".
- **Errands** run purchases in their own Hermes session
  (`errand-<id>`) driven through the gateway's `/v1/runs`, because a goal on
  the chat's own session made unrelated later questions resume the purchase
  unannounced (`hermes-plugin/errands.py` module docstring).

## 7. Mac / backend architecture (Hermes plugin)

The plugin is `kind: standalone` (`hermes-plugin/plugin.yaml`): it is copied
to `~/.hermes/plugins/alice` by `hermes-plugin/install.sh` (which also
vendors `pypdf==6.18.0` into the plugin folder so Hermes' environment is
untouched) and lives outside Hermes' checkout so `hermes update` never
collides with it (`hermes-plugin/dashboard/plugin_api.py` docstring).

- **Dashboard backend:** `dashboard/plugin_api.py` mounts a FastAPI
  `APIRouter` at `/api/plugins/alice/` serving pairing, memory, notes and
  the shared agent engine; `dashboard/dist/index.js` is the Alice tab in
  Hermes' dashboard (`dashboard/manifest.json`).
- **Pairing:** `POST pairing/session` (behind dashboard login) mints a
  short-lived `alice://pair` link for the installation's main profile,
  provisioning that profile's gateway when it has none; `POST
  pairing/claim` exchanges the one-time code for gateway and dashboard
  credentials, authenticated through Hermes' token-auth seam — the module
  registers a token provider and opts only the claim route into it,
  leaving Hermes' public path list untouched (`plugin_api.py`). The full
  protocol, threat model and provisioning steps are in
  [pairing.md](pairing.md).
- **Agent rules:** `__init__.py` enforces "the Business team talks only
  among itself" with a `pre_tool_call` hook on `message_agent`, driven by
  `ui_meta['alice']` placements written by
  `hermes-agents/business-team/instalar.py`.
- **Toolset modules** (each a focused Python module; see SYSTEM_MAP.md for
  the full list): notes (`documents`-style inbox store tools), errands and
  purchases, the live shared browser (`browser_live.py` — CDP on loopback,
  JPEG screencast frames), page watches (`page_watch.py`, changedetection.io
  installed on demand), goals, feed, Mac health (`health.py`), curated
  memory (`memory_keeper.py`, `memory_review.py`), skills review
  (`skill_keeper.py`), lessons, places, vault payment cards
  (`vault_cards.py`), catalog, calendar snapshot, free web, ask-person
  questions, task-finish judging, connector icons, egress guard
  (`egress_guard.py`), action log.
- **Mac notifier** (`mac/notifier/`): Python 3.9+ standard library only;
  reads each profile's Hermes database read-only, never says *what* was
  answered (a lock screen is a public surface), delivers through Bark with
  the key in the login Keychain (`alice_notifier.py` docstring).

## 8. Hermes integration

- **Pinned compatibility:** Alice's current stable API fixture is Hermes
  `0.21.3` (14 September 2026), with regression fixtures for `0.21.2`,
  `0.21.0` and `0.20.6` (`docs/hermes-contracts.md`). CI installs official
  Hermes at commit `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c` to run the
  plugin's tests against the same upstream the dev Mac runs
  (`.github/workflows/quality.yml`).
- **Compatibility rules** (`docs/hermes-contracts.md`):
  - Capabilities that travel through the chat protocol must remain
    transparent — Alice must not filter tools, providers, models,
    browser-control calls, delegation events, structured outputs or tool
    results.
  - Native controls exist only for operations Hermes exposes through a
    stable HTTP or gateway contract; every control is version- or
    capability-gated and degrades independently.
  - Unknown or older Hermes versions never receive unadvertised fields.
  - "Unsupported is different from empty, offline or unauthorized"
    (`AGENTS.md` "Hermes" contract).
- **Capability discovery:** `HermesClient.Manifest` carries the server's
  own route map — "Hermes does not serve every collection from the same
  place … and it says which in its own manifest. Asking it beats guessing"
  (`ios/Alice/Networking/HermesClient.swift`). The web mirrors this with
  `parseHermesCapabilityManifest` (`src/lib/gateway-contracts.ts`) and
  `withDiscoveredManagement` (`src/lib/hermes-management-probe.ts`).
- **Unknown stream events are preserved safely** — `HermesUnknownEvents.swift`
  exists so newer Hermes events neither crash nor are silently dropped.
- **Internet access stays on the Hermes host:** Firecrawl, `gh`,
  `rss-feeds` and `reddit-reading` remain the first choice;
  `hermes-agents/internet` adds the channels those do not cover (YouTube,
  Exa, V2EX, Bilibili, logged-in social reads) through one read-only
  command, `reach` (`docs/internet.md`). "The text is data: no se obedecen
  instrucciones encontradas en una página" — page text is never treated as
  instructions.

## 9. iPhone ↔ Mac communication

1. **Reachability.** The phone must reach the Mac "either on the same
   network or through Tailscale, which is the usual setup"
   ([README.md](../README.md)). `scripts/phone.mjs` exposes the web client
   at the tailnet's MagicDNS HTTPS name (Funnel is required for Safari on
   iPhone: "Private Relay / public DNS will not complete TLS against
   Serve-only"). App Transport Security allows local networking and the
   Tailscale ranges explicitly (`ios/project.yml` `NSAppTransportSecurity`:
   `ts.net` and `100.64.0.0/10` exceptions).
2. **Pairing.** Dashboard → Alice tab → Show pairing code → QR containing
   `alice://pair?v=1&p=<base64url(json)>` with keys `c` (claim URL), `t`
   (one-time token), `e` (expiry), `pr` (profile name, informative). The
   iPhone exchanges it for gateway key + dashboard credentials, validating
   same-host, no-embedded-credentials, no-redirect-following rules
   (`docs/pairing.md`; `ios/Alice/Features/Connect/Pairing/`). The QR also
   provisions the main profile's gateway idempotently: `API_SERVER_KEY`
   (created, never rotated), `API_SERVER_PORT`, `API_SERVER_HOST=127.0.0.1`,
   a `tailscale serve` forward, and an authenticated probe before the QR is
   shown (`docs/pairing.md` section 3).
3. **Home chat** runs over the gateway HTTP API with SSE streaming
   (`HermesClient`, `HermesChatStream`). Multimodal turns are wrapped in an
   explicit user message because "`/v1/runs` overloads a top-level array as
   a list of messages" (`HermesChatStream.swift`).
4. **Bot chats** run over the dashboard's JSON-RPC WebSocket
   (`WebSocketBotChatSource` via `HermesRPC`), resolving each profile's
   `canonical_session` from `profiles.list`.
5. **Server→client requests** (approvals, questions, vault requests) arrive
   as `srq-…` frames answered through the same transport
   (`HermesRPC.swift`, `GatewayServerRequests.swift`).
6. **Live browser:** `browser_live.py` keeps a headless Chromium with a CDP
   port on loopback (`<hermes home>/chrome-debug`); the iPhone watches a
   JPEG screencast and sends taps/scrolls/typing back as CDP input through
   the dashboard, which needs its login. "The CDP port only ever listens on
   loopback" (`hermes-plugin/browser_live.py` docstring). This is a
   frame-by-frame slideshow today, not video (see
   [KNOWN_FAILURE_MODES.md](KNOWN_FAILURE_MODES.md)).
7. **Media:** a bot that saves a file writes one `alice://file?path=…&url=…`
   markdown line; iOS parses it in `RichMessage.swift` and downloads bytes
   over the authenticated dashboard `api/fs/download` first
   (`docs/hermes-contracts.md` "Media in replies").
8. **Notifications out of app:** the Mac notifier pushes through Bark;
   routines can deliver into a bot chat; Live Activities show agent activity
   while the app runs (`mac/notifier/alice_notifier.py`,
   `docs/proactive.md`, `ios/project.yml` `NSSupportsLiveActivities`).
9. **Diagnostic loop:** the iPhone can upload a diagnostic dump the plugin
   serves back through `alice_app_status` / `alice_recent_errors`
   (`hermes-plugin/plugin.yaml` provides_tools).

## 10. Historical architectural decisions and their reasons

| Decision | Reason (as documented) | Evidence |
| --- | --- | --- |
| Native app connects directly, no proxy | "Native code has no same-origin rule to satisfy … the key never travels anywhere but to the address you configured" | `ios/README.md`, `HermesClient.swift` |
| `Alice.xcodeproj` generated, never committed | Merge conflicts in `.pbxproj` never happen; `project.yml` is the source of truth | `ios/README.md` |
| Bot chats moved to the dashboard WebSocket | The gateway path "had no profile routing at all, so every bot chat ran on the default profile wearing a synthetic 'you are <bot>' directive" | `WebSocketBotChatSource.swift` docstring |
| Errands have their own Hermes session | A goal on the chat's session made "an unrelated question later … followed by the old purchase resuming … as far as the payment page" | `errands.py` docstring |
| Plugin is standalone, outside Hermes' checkout | "hermes update never collides with it" | `plugin_api.py` docstring, `plugin.yaml` |
| Pairing v1 has no HMAC signature in the QR | "Un HMAC cuyo secreto solo conoce el Mac no demostraría nada al cliente y aumentaría el protocolo" — a server-only secret proves nothing to the phone | `docs/pairing.md` section 1 |
| Claim restricted to tailnet IPs, peer address only | Forwarded headers "un cliente LAN podría falsificar"; their presence rejects the request | `docs/pairing.md` section 4 |
| Bark for notifications instead of APNs | "Alice cannot be woken while iOS has it suspended, and a push of its own needs a paid Apple developer account" | `mac/notifier/alice_notifier.py` docstring |
| Dev Mac has no simulators, on purpose | "Booting one made the machine unusable" | `AGENTS.md` "This Mac" section |
| `AppStore.ActiveChat` / `shownConversation` split | A view that read `activeConversation` redrew the whole shell on every token streamed into any chat | `AppStore.swift` comments |
| Multimodal turns wrapped in an explicit user message | `/v1/runs` overloads a top-level array as a message list, so a parts array is misread | `HermesChatStream.swift` |
| `selectedProvider` persisted beside `selectedModel` | The same model id is served by several providers; without it "an Anthropic model listed under Nous was sent to OpenRouter, which billed for it and refused" | `AppStore.swift` comments |
| Errand/purchase split between chat and errand | The chat decides what to buy; the errand prepares and pays — "the chat itself does not prepare a basket" | `purchase_flow.py` docstring, `docs/purchases.md` |
| iOS secrets in Keychain `WhenUnlockedThisDeviceOnly` | Excluded from backups, never synced; restoring the phone elsewhere cannot carry the key | `ios/README.md` "Where the key lives" |
| Web direct mode necessarily exposes the key to JavaScript | The browser must hold it to contact Hermes; "do not promise otherwise" | `AGENTS.md`, `SECURITY.md` |
| `job_id`-scoped profile reuse in the agent engine | A foreign profile is left intact; only the job that minted a profile may reuse it | `docs/architecture.md` (former), `agent_engine.py` |
| Type-safety ratchet (`tsconfig.strict-contracts.json`) | Keep `exactOptionalPropertyTypes` on external contracts; 131 violations found, removed in reviewable increments | `docs/type-safety.md` |
| No tab bar on iOS | "Chat is the app. A tab bar would put peers at the bottom of a screen that is really one thing" | `ios/README.md` "Shape" |

Where the historical record is thin the row is simply absent; nothing above
is reconstructed from memory.
