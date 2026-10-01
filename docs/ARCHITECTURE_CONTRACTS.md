# Architecture Contracts

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`
>
> These contracts are inferred from the working implementation, Git history,
> tests, and existing documentation. They are not an ideal architecture —
> they are the invariants the current system depends on to remain coherent.

## Contract 1: Connection identity ownership

**CONTRACT**
The home conversation belongs to the installation's main profile. Bot
chats carry their own profile and canonical session. An `@agent` reply
retains its own profile and session on the message. Navigating between
chats must not retarget an in-flight turn.

**WHY IT EXISTS**
Mixing profile/session identity between conversations would send messages
to the wrong agent, retry writes against the wrong profile, or change an
agent's model from another chat. Real-world use exposed these failures.

**CURRENT EVIDENCE**
- `HomeChatSession.swift` — home chat always uses the main profile.
- `BotChatSession.swift` — each bot chat carries its own profile and
  canonical session.
- `AgentTaskSession.swift` — independent tasks use profile-scoped
  `session.create` / `session.resume`.
- `ChatTurnRoute.swift` — determines method while preserving identity.
- `AGENTS.md` documents the invariant explicitly.

**FILES/SUBSYSTEMS INVOLVED**
`HomeChatSession.swift`, `BotChatSession.swift`, `AgentTaskSession.swift`,
`ChatTurnRoute.swift`, `AppStore.swift`, `HermesRPC.swift`

**WHAT BREAKS IF VIOLATED**
Messages sent to wrong agent. Writes retried against wrong profile. Model
changes applied to wrong agent. Drafts appear in wrong chat. Approvals
routed to wrong session.

**HOW A HUMAN CAN VERIFY IT**
Open multiple bot chats and the home chat. Send messages in each. Switch
between them while a message is streaming. Verify the profile and session
are preserved per conversation.

**HOW AN AI AGENT CAN VERIFY IT**
Read `HomeChatSession`, `BotChatSession`, and `AgentTaskSession`. Verify
that profile and session are set at creation and never changed by
navigation. Run `HomeChatSessionTests`, `BotChatSessionTests`,
`AgentTaskSessionTests`, `ChatTurnRouteTests`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Partially. Unit tests enforce the contracts. A lint rule could check that
`AppStore.send()` always uses a session-scoped route, but the boundary is
subtle and prone to false positives.

---

## Contract 2: Gateway key storage boundary

**CONTRACT**
The gateway key is stored in iOS Keychain with class
`WhenUnlockedThisDeviceOnly`. It is never stored in `localStorage`,
`UserDefaults` (as plaintext), or logs. The web companion stores it in an
encrypted httpOnly cookie (proxy mode) or `sessionStorage` + encrypted
cookie (direct mode).

**WHY IT EXISTS**
The gateway key is the asset worth protecting. Anyone who can reach the
agent's address with a valid key can act as the user.

**CURRENT EVIDENCE**
- `KeyStore.swift` — Keychain wrapper.
- `SECURITY.md` — threat model and key storage table.
- `hermes_gate` table — sealed token per user (web).
- `gateway.server.ts` — server proxy with encrypted cookie.
- `hermes-direct.ts` — direct browser transport.

**FILES/SUBSYSTEMS INVOLVED**
`KeyStore.swift`, `AppStore.swift` (connect/connectDashboard),
`SECURITY.md`, `hermes_gate` table, `gateway.server.ts`, `hermes-direct.ts`

**WHAT BREAKS IF VIOLATED**
Key exposed in logs, browser dev tools, or backups. Unauthorized access to
Hermes agent.

**HOW A HUMAN CAN VERIFY IT**
Check Keychain Access on iPhone. Check browser dev tools for the key. Check
server logs for the key value.

**HOW AN AI AGENT CAN VERIFY IT**
`rg "gateway.*key|api.*key|apiKey|API_KEY" ios/Alice/ --type swift` and
verify results are in `KeyStore.swift` or `AppStore.connect`. Check that
`HermesClient` never logs the key. Check that web code never puts the key
in `localStorage`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Partially. Gitleaks scans for secrets. A custom lint rule could enforce
that Keychain is the only persistence for the gateway key on iOS.

---

## Contract 3: Codable backward compatibility

**CONTRACT**
Old Codable archives must be readable before extending persisted models.
A Swift property default does NOT make synthesized decoding
backward-compatible. Unreadable archives are retained for recovery, never
replaced with empty ones.

**WHY IT EXISTS**
Users have conversations stored in UserDefaults. A breaking Codable change
would lose all stored conversations.

**CURRENT EVIDENCE**
- `ConversationArchive.swift` — reads old blob format, rewrites in split
  form. Unreadable bytes retained.
- `AGENTS.md` — documents the invariant explicitly.
- `ConversationMigrationTests.swift`, `ConversationArchiveTests.swift`,
  `ConversationPersistenceTests.swift` — test backward compatibility.

**FILES/SUBSYSTEMS INVOLVED**
`ConversationArchive.swift`, `ConversationStorage.swift`, all `Models/*.swift`
that are `Codable` and persisted.

**WHAT BREAKS IF VIOLATED**
Data loss. Conversations disappear on app update. Unreadable archives
silently overwritten.

**HOW A HUMAN CAN VERIFY IT**
Install an older build, create conversations, then install the new build.
Verify conversations are preserved.

**HOW AN AI AGENT CAN VERIFY IT**
Read `ConversationArchive.load()`. Verify it handles `.blob` and `.split`
sources. Verify `.unreadable` case retains bytes. Run
`ConversationMigrationTests`. Check that any new `Codable` property has a
custom decoder or is truly optional with `decodeIfPresent`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Partially. Tests enforce it for known archive versions. A build-time check
could flag new non-optional `Codable` properties on persisted models.

---

## Contract 4: No automatic retry of mutations

**CONTRACT**
Alice never automatically retries a mutable Hermes action. Reads may be
deduplicated and cached (30-second TTL), but mutations are never
auto-retried. Idempotency keys are used where the transport supports them.

**WHY IT EXISTS**
Retrying an uncertain mutation can repeat an external effect (send a
message twice, pay twice, create a duplicate profile).

**CURRENT EVIDENCE**
- `docs/request-lifecycle.md` — documents the contract.
- `hermes-transport.ts`, `hermes-connection.ts` — read deduplication.
- `shared-read-cache.ts` — 30-second TTL for reads.
- `store.ts` — Zustand store with mutation handling.

**FILES/SUBSYSTEMS INVOLVED**
`hermes-transport.ts`, `hermes-connection.ts`, `shared-read-cache.ts`,
`store.ts`, all mutation handlers.

**WHAT BREAKS IF VIOLATED**
Duplicate messages, duplicate payments, duplicate profile creation.
External side effects repeated.

**HOW A HUMAN CAN VERIFY IT**
Trigger a network failure during a mutation. Verify it fails visibly, not
silently retries.

**HOW AN AI AGENT CAN VERIFY IT**
`rg "retry|retryCount|attempts" src/lib/ --type ts` and verify no mutation
handler has auto-retry logic. Check that read caches are invalidated on
mutations.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Partially. Tests enforce per-subscriber cancellation and invalidation. A
lint rule could flag `retry` patterns near mutation code.

---

## Contract 5: Egress guard on tainted sessions

**CONTRACT**
After an agent reads outside content (web page, email, file), the session
is tainted for 6 hours. In a tainted session, terminal or code commands
that could send data out or read secrets require user approval. The exact
command is shown.

**WHY IT EXISTS**
A prompt injection on a web page can make the model want to exfiltrate
data. The egress guard ensures it cannot happen without the person seeing
it. Modeled after Meta's Muse trust decision.

**CURRENT EVIDENCE**
- `egress_guard.py` — `observe()`, `tainted()`, `risk()` functions.
- `READS_OUTSIDE`, `RUNS_CODE`, `_EGRESS`, `_SECRETS` regex patterns.
- `test_egress_guard.py` — tests.
- `plugin.yaml` — `pre_tool_call` hook registered.

**FILES/SUBSYSTEMS INVOLVED**
`egress_guard.py`, `plugin_api.py` (hook registration)

**WHAT BREAKS IF VIOLATED**
Prompt injection leads to data exfiltration or secret theft without user
knowledge.

**HOW A HUMAN CAN VERIFY IT**
Have an agent read a web page, then try to `curl` data out. Verify the
approval card appears with the exact command.

**HOW AN AI AGENT CAN VERIFY IT**
Read `egress_guard.py`. Verify `READS_OUTSIDE` covers all tools that bring
outside content. Verify `_EGRESS` and `_SECRETS` patterns are
comprehensive. Run `test_egress_guard.py`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Yes. The `pre_tool_call` hook is automatically invoked by Hermes. The
regex patterns are deterministic.

---

## Contract 6: Business team message isolation

**CONTRACT**
A Business team agent can only message teammates in its channel. Agents
outside Business cannot message Business members. Internal profiles
neither send nor receive. If the rule cannot be checked, the message does
not go.

**WHY IT EXISTS**
Business team agents handle sensitive operations and should not be
reachable by arbitrary agents.

**CURRENT EVIDENCE**
- `plugin_api.py` — `pre_tool_call` hook on `message_agent`.
- `hermes-agents/business-team/instalar.py` — sets `ui_meta['alice'].channel`.
- `test_business_isolation.py` — tests.

**FILES/SUBSYSTEMS INVOLVED**
`plugin_api.py`, `hermes-agents/business-team/`

**WHAT BREAKS IF VIOLATED**
Unauthorized agents can message Business team members. Business team
members can message external agents.

**HOW A HUMAN CAN VERIFY IT**
Create a Business team agent and a non-Business agent. Try to send
messages between them. Verify they are blocked.

**HOW AN AI AGENT CAN VERIFY IT**
Read the `pre_tool_call` hook in `plugin_api.py`. Verify it checks
`ui_meta['alice'].channel`. Run `test_business_isolation.py`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Yes. The hook is automatically invoked by Hermes.

---

## Contract 7: Pairing token security

**CONTRACT**
Pairing tokens are one-time, short-lived (5 min), same-host-restricted,
loopback + Tailscale only. No redirects. No `X-Forwarded-For` accepted. No
persistence (in-memory only). No secrets in logs. Cache-Control: no-store.

**WHY IT EXISTS**
The pairing token is a bearer secret that delivers the gateway key and
dashboard credentials. Anyone holding it who can reach the allowed network
can claim it once.

**CURRENT EVIDENCE**
- `plugin_api.py` — `PairingCodeProvider`, offer storage, claim handler.
- `docs/pairing.md` — full protocol documentation.
- `PairingClient.swift`, `PairingPayload.swift` — iOS client.
- `PairingClientTests.swift`, `PairingPayloadTests.swift` — tests.

**FILES/SUBSYSTEMS INVOLVED**
`plugin_api.py`, `PairingClient.swift`, `PairingPayload.swift`,
`PairingFlow.swift`, `HermesAddress.swift`

**WHAT BREAKS IF VIOLATED**
Token replay. Token theft via redirect. Token theft via header spoofing.
Credential leakage via logs.

**HOW A HUMAN CAN VERIFY IT**
Scan a QR, wait 6 minutes, try to scan again. Verify it fails. Try to
claim from a non-Tailscale address. Verify it's rejected.

**HOW AN AI AGENT CAN VERIFY IT**
Read `plugin_api.py` pairing handlers. Verify TTL, one-time use, same-host
validation, no redirects, peer address (not headers), no persistence, no
logs of secrets. Run `PairingClientTests`, `PairingPayloadTests`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Yes. The implementation is deterministic. Tests enforce the contract.

---

## Contract 8: Unknown Hermes event preservation

**CONTRACT**
Unknown Hermes stream events must be preserved safely, not dropped. A new
Hermes version may send event types Alice doesn't recognize yet.

**WHY IT EXISTS**
Hermes evolves independently. Dropping unknown events would lose
information and break silently on Hermes updates.

**CURRENT EVIDENCE**
- `HermesUnknownEvents.swift` — preserves unknown events.
- `HermesRunProtocol.swift` — protocol-level handling.
- `AGENTS.md` — "Preserve unknown stream events safely."
- `HermesUnknownEventsTests.swift`, `HermesRunProtocolTests.swift` — tests.

**FILES/SUBSYSTEMS INVOLVED**
`HermesUnknownEvents.swift`, `HermesRunProtocol.swift`,
`HermesChatStream.swift`

**WHAT BREAKS IF VIOLATED**
Silent data loss on Hermes updates. Missing agent activity or approvals.

**HOW A HUMAN CAN VERIFY IT**
Developer → Checks → "Hermes messages Alice does not understand yet."

**HOW AN AI AGENT CAN VERIFY IT**
Read `HermesUnknownEvents.swift`. Verify unknown event types are stored,
not dropped. Run `HermesUnknownEventsTests`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Partially. Tests enforce it for known unknown types. A fuzz test could
generate random event types.

---

## Contract 9: Web account isolation

**CONTRACT**
Web state is persisted per account. Persisted updates are immutable. The
account verifier is immutable. Pull cursor is saved with corresponding
state. Account changes cancel work from the old account. Cache is
separated by account.

**WHY IT EXISTS**
Multiple users may share a server. State leakage between accounts would
expose private conversations.

**CURRENT EVIDENCE**
- `migrations/0003_encrypted_sync.sql` — per-user records.
- `sync-crypto.ts` — E2EE per account.
- `hybrid-storage.ts` — cache separated by account.
- `shared-read-cache.ts` — includes account identity.
- `docs/request-lifecycle.md` — documents isolation.

**FILES/SUBSYSTEMS INVOLVED**
`hybrid-storage.ts`, `shared-read-cache.ts`, `sync-crypto.ts`,
`sync-store.server.ts`, `auth/isolation.server.ts`

**WHAT BREAKS IF VIOLATED**
Cross-account data leakage. Conversation sync corruption. Cache poisoning.

**HOW A HUMAN CAN VERIFY IT**
Sign in as user A, create conversations. Sign out, sign in as user B.
Verify no data from A appears.

**HOW AN AI AGENT CAN VERIFY IT**
`rg "user_id|userId|account" src/lib/ --type ts` and verify all
persistence includes account scoping. Check `auth/isolation.server.ts`.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Partially. Database schema enforces `user_id` constraints. Server-side
query scoping is a code review concern.

---

## Contract 10: iOS render-thread safety

**CONTRACT**
UI code must not perform expensive work on the main thread. `AppStore` is
`@MainActor` but heavy operations (encoding, network) must be off-thread.
`ConversationArchive` prepares writes off the main thread.

**WHY IT EXISTS**
Main-thread stalls cause dropped frames and hitches. The HitchMonitor
tracks freezes.

**CURRENT EVIDENCE**
- `scripts/check-ios-render-reads.mjs` — static check for render-thread
  safety.
- `HitchMonitor.swift` — runtime freeze detection.
- `ConversationArchive.swift` — `PreparedWrite` prepared off main thread.
- `npm run ios:render-check` — CI check.
- `StallSampler.swift` — main-thread stack sampling.

**FILES/SUBSYSTEMS INVOLVED**
`AppStore.swift`, `ConversationArchive.swift`, `HitchMonitor.swift`,
`StallSampler.swift`, `scripts/check-ios-render-reads.mjs`

**WHAT BREAKS IF VIOLATED**
UI freezes, dropped frames, poor user experience.

**HOW A HUMAN CAN VERIFY IT**
Enable Developer → Performance meter. Watch for freezes during chat,
scrolling, and navigation.

**HOW AN AI AGENT CAN VERIFY IT**
Run `npm run ios:render-check`. Check that `ConversationArchive` uses
`PreparedWrite` for off-thread encoding. Verify no `@MainActor` function
calls `JSONEncoder` or `JSONSerialization` on large data.

**CAN IT BE AUTOMATICALLY ENFORCED?**
Yes. `npm run ios:render-check` is a static check that runs in CI.
