# Alice — Data Flow, State and Persistence

How data moves through the system, where each fact lives authoritatively,
and how it is stored. Traceable to code; **UNKNOWN** marks missing evidence.

## Sources of truth

| Data | Source of truth | Notes / evidence |
| --- | --- | --- |
| Agent behavior, sessions, memory, skills, routines | **Hermes on the Mac** (`~/.hermes`) | Alice never re-implements agent state; remote jobs are authoritative (`docs/compatibility-matrix.md` "Routines") |
| Connection credentials (iOS) | Keychain `WhenUnlockedThisDeviceOnly` (`ios/Alice/Storage/KeyStore.swift`) | Never in UserDefaults (`ios/README.md`) |
| Gateway/dashboard addresses (iOS) | `AppStore` persistence + `HermesAddress` policy (`ios/Alice/Storage/HermesAddress.swift`) | Public Hermes addresses only over HTTPS; tailnet/local exceptions (`ios/project.yml` ATS) |
| Conversations (iOS) | Per-conversation UserDefaults archives (`ConversationArchive.swift`) | Old single-array blob still read and rewritten split; unreadable bytes retained |
| Web accounts | Postgres via Better Auth (`migrations/0001_auth.sql`) | — |
| Web Hermes connection | `hermes_gate` table, sealed (`migrations/0002_hermes_gate.sql`) | Looked up by `user_id` when the cookie is missing |
| Web conversation sync | `alice_sync_record`, ciphertext only (`migrations/0003_encrypted_sync.sql`, `0005_sync_verifier.sql`) | E2EE; client-side merge `src/lib/sync-merge.ts` |
| Product catalogue for purchases | Shop catalog via `catalog.py` + the real shop page | `catalog_search` cannot buy (`docs/purchases.md` step 3) |
| Payment cards | **Hermes' vault**, bound to an origin (`vault_cards.py`, `/api/plugins/alice/vault/cards`) | Card numbers never pass through chat |
| Health / calendar / reminders | The iPhone's own stores, read-only (`HealthSync.swift`, `CalendarSync.swift`, `ios/project.yml` usage descriptions) | Summaries shared with the person's own Hermes only |
| Mac health | `health.py` live reading of CPU/memory/processes | Served to the app; morning briefing |
| Feed content | RSS from EL PAÍS / BBC / NASA, ranked on-device (`Features/Feed`, `feed.py`) | "Preferences stay on the device" (`docs/verification.md`) |

## State management

- **iOS:** one `@MainActor @Observable` `AppStore` holds all UI state
  (`AppStore.swift`). The `ActiveChat`/`shownConversation`/`conversation(_:)`
  split exists so a view reading the on-screen chat does not observe the
  whole conversation array (redraw-storm fix documented in the file's
  comments). Derived shelves (`pinnedConversations`,
  `recentConversations`) are recomputed only on array change.
- **Web:** zustand stores (`src/lib/store.ts`) plus per-operation caches:
  concurrent model reads share one transport request per account/connection/
  profile, successful model reads have a 30-second TTL, failures are never
  cached, and account changes or mutations invalidate the cache
  (`docs/request-lifecycle.md`).
- **Writes:** "Alice never automatically retries a mutable Hermes action";
  run starts use deterministic idempotency keys when the transport supports
  them; polling stops when its owning view or account disappears
  (`docs/request-lifecycle.md`).

## Persistence

### iOS

- **Keychain**: gateway key, dashboard password, Bark-adjacent secrets —
  `WhenUnlockedThisDeviceOnly`, excluded from backups
  (`ios/README.md`, `KeyStore.swift`).
- **UserDefaults**: theme, accent, addresses, model choice, recent models,
  provider, per-conversation archives, drafts
  (`AppStore.swift` `Keys`, `ConversationArchive.swift`,
  `ComposerDraftArchive.swift`). Drafts are debounced per chat with a
  synchronous background save; text and attachments use separate records so
  unchanged image bytes are not rewritten
  (`docs/quality-audit-2026-09-25.md`).
- **Backward compatibility:** "A Swift property default does not make
  synthesized decoding backward-compatible" — `read old Codable archives
  before extending persisted models`; `RetiredPreferences.swift` handles
  removed keys (`AGENTS.md` Data contract).
- **Scope of stores:** gateway address policy lives in `HermesAddress`,
  conversation archives in `ConversationArchive`, bot layout in
  `BotChannel` (former `docs/architecture.md`, now
  [ARCHITECTURE.md](ARCHITECTURE.md) §5–6). "A future move to a database
  must include migration and recovery tests."
- **App lock / Face ID:** `AppLock.swift`, `Biometrics.swift`.

### Web

- **Local:** PGLite in the browser via Kysely (`src/lib/db.ts`); the same
  migrations apply automatically on startup (`migrations/0001` header).
- **Server (production):** Neon Postgres through `npm run db:migrate`
  (`docs/release-operations.md`).
- **Sync model:** device keys + conversation replicas + an immutable
  server-side verifier; a pull cursor is saved with the state it belongs to;
  "Disconnection, retries and key mismatch are different states, not a
  single on/off preference" (`docs/architecture.md` former text, kept in
  ARCHITECTURE.md; `src/lib/sync-runtime-client.ts`).

## Networking

### iOS transports

- `HermesClient` (actor) — gateway HTTP: manifest/capabilities, models,
  chat runs; key-authenticated; no redirects followed.
- `HermesChatStream` — streaming runs over the gateway; run recovery has a
  180-second budget that "restarts whenever a status probe is answered"
  (`HermesChatStream.swift` `RunRecoveryBudget`).
- `HermesRPC` + `WebSocketBotChatSource` — dashboard JSON-RPC WebSocket;
  profile-scoped `session.create`/`session.resume`; canonical session from
  `profiles.list`.
- `DashboardClient`, `HermesManagement` — dashboard HTTP management
  endpoints; a management endpoint may be separate from the chat API.
- `GatewayServerRequests` — answers Hermes' server→client questions
  (`srq-…`): approvals, vault requests, secure input.
- Origin rules: native requests and redirects are restricted to the
  configured service origin (`SECURITY.md`).

### Web transports

Two transports with equivalent semantics, resolved per operation by
`resolveHermesTransport` (`src/lib/hermes-transport.ts`):

- **Authenticated server proxy** — the browser never holds the key; the
  server decrypts the sealed `httpOnly` cookie credential to contact
  Hermes (`gateway.server.ts`, `SECURITY.md` key table).
- **Direct browser** — the authenticated `device-secret` API returns the
  key to the browser so it can contact Hermes itself
  (`hermes-direct.ts`); necessarily exposed to JavaScript.

Outbound safety: `pinnedFetch` with `assertPublicHttpUrl` /
`UnsafeOutboundUrlError` and private-hostname checks
(`src/lib/outbound-http.server.ts`, used by `gateway.server.ts`); the
plugin guards its own egress (`hermes-plugin/egress_guard.py`).

## Streaming

- Chat replies stream as SSE events from the gateway; the iOS client
  preserves unknown event types safely (`HermesUnknownEvents.swift`) and
  the web has a dedicated fallback path
  (`src/lib/chat-stream-fallback.test.ts`).
- Streaming updates follow the response only "when the reader has not
  intentionally scrolled away" — virtualization invariants
  (`docs/chat-virtualization.md`; >60 messages render only viewport +
  640 px overscan; height changes above the viewport compensate
  `scrollTop`).
- The live browser view is a JPEG-frame screencast over long-polling from
  the Mac's Chromium (CDP); taps, scrolls and typing return as CDP input
  (`browser_live.py`). It is a slideshow today, not video
  (`docs/HANDOFF.md` open problem 2).
- `EventResume.swift` and `RoutineQuietRuns.swift` recover events missed
  while the app was suspended or a routine ran quietly.

## Background execution (iOS)

- Declared: `UIBackgroundModes: [fetch]` with
  `BGTaskSchedulerPermittedIdentifiers: [com.freixanet.alice.refresh]`
  (`ios/project.yml`).
- Reality: "iOS background execution is opportunistic; do not promise
  always-on delivery while the app is closed" (`AGENTS.md` Notifications
  contract). Notification copy is written to match that
  (`ios/project.yml` comment above `UIBackgroundModes`).
- While closed, delivery is what Hermes already has: routines delivering
  into a bot chat, Bark pushes from the Mac notifier, Live Activities
  while the app runs (`docs/proactive.md`).
- An approval sent while the phone was locked comes back into the chat
  when it is reopened ([README.md](../README.md) purchase section).

## Key end-to-end flows

### A chat turn (home)

Composer → `AppStore` → `HomeChatSession` → `HermesClient`/`HermesChatStream`
→ gateway `/v1/runs` (SSE) → stream events appended to the conversation →
archive save (per-conversation key). Approvals and questions arrive as
server→client requests via `GatewayServerRequests` and render as cards.

### A chat turn (bot/agent)

`BotChatSession` resolves the profile's canonical session
(`WebSocketBotChatSource.canonicalBotChat` via `profiles.list`) → turn sent
over the dashboard JSON-RPC WebSocket → events stream back on the same
socket → answers, failures and actions are surfaced as felt feedback
(commit `ec451b8` "answers and failures are felt").

### Buying (twelve steps)

Clarify → context → search (catalog + shop) → verify (`purchase_options`
validates https page, stock, price, currency) → show cards → choose
(`[elección:<id>]`, hidden id, options expire after three days) → errand
starts with its own session carrying the chosen option → card check
(vault) → checkout summary → approval (server binds the approval to the
checkout; Face ID confirms; pay gate refuses any paying click until then)
→ pay (page total re-checked; payment ledger refuses a second payment
until the first outcome is known) → result distinguishes confirmed /
declined / unconfirmed (`docs/purchases.md`, `purchase_flow.py`,
`errands.py`, `purchases.py`).

### Pairing

See ARCHITECTURE.md §9 and [pairing.md](pairing.md).

### Encrypted web sync

Client derives device key → encrypts conversation replicas → pushes
records + cursor → server stores ciphertext only → second device imports
recovery phrase, validated against the immutable verifier before any
replacement ("validate a recovery key before replacing the saved key or
uploading conversations", `AGENTS.md` Sync contract;
`src/lib/sync-crypto.ts`, `sync-device-key.ts`, `sync-merge.ts`).

### Media in replies

Bot writes `![name.ext](alice://file?path=…&url=…)` → `RichMessage.swift`
parses → `RichMediaLoader` downloads once per media per session over the
authenticated dashboard `api/fs/download`, falling back to the `url` mirror
→ playback from the local file (`docs/hermes-contracts.md`).
