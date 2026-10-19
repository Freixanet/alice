# Data Flow

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document traces how data moves through Alice, from user input to
persistence and back. Every flow is traceable to code.

## Chat message flow (iOS)

```
User types in Composer
  → ComposerDraftArchive saves draft (debounced, per-chat)
  → User taps Send
  → AppStore.send(text, attachments)
    → HomeChatSession or BotChatSession determines routing
      → Profile + session identity preserved
      → ChatTurnRoute determines method (chat.run / session.create / session.resume)
    → HermesClient or HermesRPC sends request
      → Gateway: POST /v1/chat or WebSocket JSON-RPC
      → Authorization: Bearer <gateway key from Keychain>
    → Response: WebSocket event stream
      → HermesChatStream parses events:
        - text_delta → append to message
        - tool_call → render tool activity
        - tool_result → render result
        - subagent.start/complete → render subagent activity
        - question (srq) → GatewayServerRequests → ClarifyQuestions card
        - approval (srq) → GatewayServerRequests → approval card
        - error → show failure
        - done → finalize message
      → EventResume tracks seq for resume on reconnect
    → AppStore.conversations updated (per-chat, main actor)
    → ConversationArchive persists (per-chat, off main thread)
      → Only changed chats encoded (fingerprint comparison)
      → Old blob still readable, rewritten split on first save
    → SwiftUI views re-render
```

**Key files:** `ChatScreen.swift`, `Composer.swift`, `AppStore.swift`,
`HomeChatSession.swift`, `BotChatSession.swift`, `HermesChatStream.swift`,
`ConversationArchive.swift`

**Critical invariant:** Navigating to another chat must not retarget an
in-flight turn. Each conversation retains its own profile and session.
([AGENTS.md](../AGENTS.md))

## Streaming and reconnect flow

```
WebSocket connects → events arrive with seq numbers
  → EventResume tracks last seen seq per session
  → If WebSocket drops:
    → Reconnect attempt
    → session.events.since(lastSeq) → missed events
    → Merge missed events into conversation
    → Continue live stream
  → If app backgrounds:
    → Save current conversation state
    → On foreground: resume from last seq
  → If Hermes restarts:
    → Probe gateway connectivity
    → Reconnect WebSocket
    → Resume sessions
```

**Key files:** `HermesChatStream.swift`, `EventResume.swift`,
`HermesRPC.swift`, `HermesClient.swift`

## Approval flow

```
Hermes agent reaches a point needing user approval
  → Hermes sends server→client JSON-RPC request (srq-… id)
  → HermesRPCEvent with question/approval type
  → GatewayServerRequests routes to handler
  → AppStore surfaces approval card in chat:
    - Payment approval: exact total, card last 4
    - Egress approval: exact command shown
    - Clarify question: answer input
  → User responds:
    → HermesRPC.respond(toServerRequest: result:)
    → Gateway resumes agent execution
  → If phone was locked:
    → Notification queued (opportunistic)
    → Card appears when app opens
```

**Key files:** `GatewayServerRequests.swift`, `ChatTurnRoute.swift`,
`SecureRequestSheet.swift`, `PaymentCardOfferCard.swift`

## Secure credential flow

```
Agent needs a secret (API key, login, card, OTP)
  → Agent ends reply with markdown link:
    [Dar clave](alice://connect/secret/NAME)
    [Añadir tarjeta](alice://connect/card?origin=…&profile=…)
    [Iniciar sesión](alice://connect/login?origin=…&profile=…)
  → iOS parses alice:// deep link
  → Shows native secure sheet:
    - SecretKeyCard → text field
    - PaymentCardOfferCard → card form
    - SecureRequestSheet → login form
  → User enters value in secure field
  → POST to Hermes plugin:
    - /api/plugins/alice/secret → secret_store.py → .env (0600)
    - /api/plugins/alice/vault/cards → vault_cards.py → Hermes vault
    - /api/plugins/alice/vault/login → vault save
  → Chat only learns it was saved (never the value)
```

**Key files:** `SecretKeyCard.swift`, `SecureRequestSheet.swift`,
`PaymentCardOfferCard.swift`, `secret_store.py`, `vault_cards.py`

**Critical invariant:** Secrets never go through chat. The value is never
logged or read back. ([SECURITY.md](../SECURITY.md))

## Purchase flow

```
1. User asks to buy something
2. Agent clarifies product (model judgement)
3. Agent calls purchase_options tool (plugin)
   → Searches Shop catalog + shop
   → Returns verified product options
4. iOS shows PurchaseOptionsCard
5. User picks an option
6. Plugin starts errand (errand_start, not at model's discretion)
   → Each errand gets own browser context
7. Agent fills basket, address, delivery
8. Checkout summary → approval card
   - Exact total, card last 4
   - "Alice will pay on this site with your Visa ···4242"
9. User taps "Pay"
   → Hermes vault.fill with saved card
   → Payment on bank page (e.g. Redsys)
10. Payment outcome:
    - Confirmed → order number shown
    - Declined → error shown
    - Failed → error shown
11. Ledger: second payment on same shop refused until first outcome known
```

**Key files:** `PurchaseOptionsCard.swift`, `ErrandBoard.swift`,
`purchases.py`, `purchase_flow.py`, `errands.py`, `vault_cards.py`

([docs/purchases.md](purchases.md))

## Background refresh flow

```
iOS wakes app (BGTaskScheduler, opportunistic)
  → AppStore.backgroundRefresh()
    → Probe gateway connectivity
    → If connected:
      → Fetch pending events since last seq
      → Check for pending approvals, questions
      → Check routine delivery schedules
      → Check place triggers
    → If pending items:
      → EventDigest routes by type:
        - Agent answer → local notification
        - Routine delivery → local notification
        - Failure → local notification
        - Approval → local notification (may wait until app open)
    → Update Live Activity if active
```

**Key files:** `AppStore.swift`, `EventDigest.swift`, `Notifier.swift`,
`PlaceWatcher.swift`, `AgentLiveActivity.swift`

**Critical invariant:** iOS background execution is opportunistic. Do not
promise always-on delivery while the app is closed. ([AGENTS.md](../AGENTS.md))

## Pairing flow

```
Mac side:
  → Dashboard → Alice tab → "Show pairing code"
  → plugin_api.py: POST /api/plugins/alice/pairing/session
    → Provision main profile gateway if none (idempotent)
    → Generate one-time token (secrets.token_urlsafe)
    → Store offer in memory (TTL 5 min)
    → Generate QR: alice://pair?v=1&p=<base64url(json)>
    → Return QR to dashboard

iPhone side:
  → Camera scans QR (or manual entry)
  → Parse alice://pair deep link
  → PairingPayload decodes base64url JSON
  → Validate: c (exchange URL), t (token), e (expiry), pr (profile)
  → POST {c} with Authorization: Bearer {t}, body: {token, device_name}
    → No redirects followed
  → Response: {profile, gateway:{url,key}, dashboard:{url,username,password}|null}
  → Validate:
    - gateway and dashboard must be http(s), no embedded credentials
    - Must be same host as exchange URL
    - HTTPS exchange cannot degrade to HTTP services
  → AppStore.connect(gateway) → KeyStore saves key to Keychain
  → AppStore.connectDashboard(dashboard) → KeyStore saves credentials
  → Show "Connected" on main profile
```

**Key files:** `PairingClient.swift`, `PairingPayload.swift`,
`PairingFlow.swift`, `PairingScanner.swift`, `plugin_api.py`

([docs/pairing.md](pairing.md))

## Web sync flow (encrypted conversation sync)

```
Device A (source):
  → User signs in (Better Auth)
  → Device key derived from recovery key (PBKDF2)
  → Conversation serialized → encrypted (AES-GCM)
  → POST /api/sync with:
    - record_id, kind, clock (wall_time, counter, device_id)
    - ciphertext, nonce, checksum, byte_size
    - tombstone flag
  → Server stores immutable record in alice_sync_record
  → Server returns revision number

Device B (target):
  → User signs in on same account
  → Enters recovery key
  → Client derives device key
  → GET /api/sync?since=<last_revision>
  → Server returns records since cursor
  → Client decrypts each record
  → Hybrid storage: IndexedDB (local) + decrypted state
  → Pull cursor saved with corresponding state

Conflict resolution:
  → Deterministic merge by clock (wall_time, counter, device_id)
  → No server-side merge logic — client decides
  → Immutable verifier prevents key mismatch
  → Recovery key validated before replacing saved key
```

**Key files:** `sync-crypto.ts`, `sync-runtime-client.ts`,
`hybrid-storage.ts`, `sync-store.server.ts`, `sync-merge.ts`,
`sync-contracts.ts`

([docs/request-lifecycle.md](request-lifecycle.md), [docs/release-operations.md](release-operations.md))

## Health data flow

```
iPhone HealthKit (read-only)
  → HealthSync reads daily summaries:
    - Sleep, steps, active energy, workouts
    - Resting heart rate, HRV
    - Mindfulness, medication
  → Sent to Hermes (one summary per day)
  → Hermes uses for:
    - Morning briefing (what stands out vs last 4 weeks)
    - Goal measurement ("sleep 7 hours", "10,000 steps")
  → Patterns from plain statistics (≥14 days, correlation ≥0.4)
  → Alice never writes to Health
```

**Key files:** `HealthSync.swift`

## Calendar/reminders flow

```
iPhone EventKit (read-only)
  → CalendarSync reads upcoming events
  → Sent to Hermes for agent planning
  → Alice adds events only when user taps "Add"
  → Reminders: title, date, list (never notes) shared with Hermes
  → Alice marks done only when user ticks
```

**Key files:** `CalendarSync.swift`, `AgendaRows.swift`, `AgendaScreen.swift`

## Memory flow (Hermes plugin)

```
Agent writes to MEMORY.md (via memory tool)
  → post_tool_call hook fires
  → memory_keeper.py records origin (agent, session, profile)
  → Cleanup runs (conservative):
    1. Clear duplicates (oldest stays)
    2. Dated events that passed (>1 day behind)
    3. "Ya no…" contradictions (newer retires older)
  → If apply=off (default): only proposes
  → If apply=on: writes through Hermes' own MemoryStore
  → Changes recorded in changes.json (full text removed, revertable)

Conversation ends (on_session_end)
  → memory_review.py waits 90 seconds
  → Reads only person's messages since last review
  → Asks model for durable facts
  → Validates: evidence must be person's words
  → At most 5 facts per look
  → Saved as 'learned' change (revertable)
```

**Key files:** `memory_keeper.py`, `memory_review.py`, `plugin_api.py`

## Egress guard flow

```
Agent runs a tool
  → post_tool_call: if tool reads outside content (web, email, file)
    → Session marked tainted (6-hour TTL)
  → pre_tool_call: if session is tainted AND tool is terminal/code
    → Check command against egress patterns:
      - curl/wget POST/PUT/PATCH
      - nc/ncat/netcat/socat/telnet
      - scp/sftp/rsync to remote
      - ssh to remote
      - sendmail/mail/mutt
      - requests.post/put/patch
      - socket.socket
    → Check against secrets patterns:
      - ~/.ssh, .aws/credentials, .netrc
      - .env files
      - Hermes vault/keychain
      - Browser cookies
    → If risk detected:
      → Hold for user approval
      → Show exact command on approval card
      → Only user's yes lets it through
  → Everything else: untouched (browsing, reading, building)
```

**Key files:** `egress_guard.py`

## Live browser flow

```
Agent navigates in shared Chromium (on Mac)
  → browser_live.py captures JPEG frames (several per second)
  → Frames sent to iPhone via long-polling
  → LiveBrowser.swift renders frames in chat
  → User can:
    → Tap to take control (control lease)
    → Hand back to agent
  → Browser outlives dashboard/gateway restart
  → Restarted errand waits for its run
```

**Key files:** `browser_live.py`, `LiveBrowser.swift`

**Known limitation:** Slideshow, not video. For real video, stream frames
over WebSocket or use WebRTC. ([docs/HANDOFF.md](HANDOFF.md))

## Agent task flow (independent tasks)

```
User starts "New Agent"
  → AgentDraft created from sentence
  → AgentTaskSession.create()
    → profile-scoped session.create (not session.resume)
    → Retains durable session before submission
    → Uses live ID for prompts
    → agentTaskID distinguishes from canonical bot chat
  → If creation response lost:
    → Recovered by unique UUID title
  → If saved session missing:
    → Fails visibly (never silently redirects)
  → Task appears in Recents
  → Opening/clearing canonical chat does not replace it
  → Retry/stop/approval use same session
```

**Key files:** `AgentTaskSession.swift`, `AgentDraft.swift`,
`agent_engine.py`

([docs/architecture.md](architecture.md))
