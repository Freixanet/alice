# Alice Golden Paths

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document defines the canonical end-to-end workflows that determine
whether Alice fundamentally works. These are the paths that, if broken, mean
Alice is not usable. They are derived from the actual product structure,
source code, navigation, backend interactions, tests, and Git history — not
invented features.

## Golden Path 1: Pair iPhone with Hermes

**USER INTENT:** Connect the iPhone to the user's Hermes installation.

**PRECONDITIONS:**
- Hermes 0.21.x running on Mac with gateway and dashboard.
- Alice plugin installed and enabled.
- iPhone and Mac on same network or Tailscale.
- Alice app installed on iPhone.

**USER ACTIONS:**
1. Open Hermes dashboard → Alice tab → Show pairing code.
2. On iPhone: open Camera or Alice → Connect → Scan pairing QR.
3. Confirm device name.
4. Tap Connect.

**EXPECTED UI STATE:** "Connecting with your Hermes…" → "Connected" on the
main profile.

**EXPECTED APP STATE:** Gateway and dashboard credentials saved in Keychain.
Gateway connection established. Dashboard connection established (or partial
if dashboard unavailable).

**EXPECTED BACKEND/HERMES BEHAVIOR:** Plugin mints a one-time token. Gateway
is provisioned if needed (port, key, launchd service, Tailscale forward).
Claim endpoint validates origin, exchanges token for credentials.

**EXPECTED PERSISTENCE:** Keychain entries for gateway URL+key and dashboard
URL+credentials. Pairing token consumed (cannot be reused).

**EXPECTED SUCCESS RESULT:** Alice shows "Hermes: Connected" in Settings. Chat
is available. Agent list is populated.

**EXPECTED FAILURE BEHAVIOR:**
- Token expired → "The code expired. Generate a new one."
- Gateway unreachable → "Alice cannot find Hermes." with network hint.
- Gateway connected, dashboard not → Partial connection. Retry dashboard only.

**RECOVERY BEHAVIOR:** Generate new QR. Check network. Restart gateway/
dashboard. Manual connection as fallback.

**PROTECTION:** Plugin pairing tests (`hermes-plugin/tests/test_plugin_api.py`).
iOS `PairingFlow` tests. Claim response validation tests.

## Golden Path 2: Send a chat message and receive a streaming reply

**USER INTENT:** Talk to Hermes and see its response appear in real time.

**PRECONDITIONS:**
- Paired (Golden Path 1 complete).
- Hermes gateway running and reachable.
- Model provider configured.

**USER ACTIONS:**
1. Open Alice → Chat.
2. Type a message.
3. Send.

**EXPECTED UI STATE:** Message appears as user bubble. Assistant bubble appears
with streaming text. Tool activity cards appear if tools are used.

**EXPECTED APP STATE:** `HomeChatSession` uses the main profile. `HermesRPC`
sends the message to the gateway. `HermesChatStream` processes SSE events.

**EXPECTED BACKEND/HERMES BEHAVIOR:** Gateway receives `POST /v1/chat` (or
`/v1/runs`). Streams SSE events: `delta`, `tool`, `tool_result`,
`approval`, `done`.

**EXPECTED PERSISTENCE:** Conversation is saved to UserDefaults under its own
key after first save. User edits persisted immediately.

**EXPECTED SUCCESS RESULT:** Complete assistant reply visible in chat.
Conversation saved.

**EXPECTED FAILURE BEHAVIOR:**
- Gateway unreachable → "Couldn't reach that address."
- Timeout → "Hermes didn't answer in time."
- Model error → Error message with model limit info.
- Bad response → "Hermes sent something Alice could not read."

**RECOVERY BEHAVIOR:** Retry sends the same message. If the gateway was
restarted, reconnect first.

**PROTECTION:** `chat-stream.test.ts`, `hermes-client.test.ts`,
`HermesChatStream.swift` tests, `ChatTurnRoute.swift` tests.

## Golden Path 3: Approve a destructive action

**USER INTENT:** Allow or deny an action Hermes requests (e.g., pay, run a
command).

**PRECONDITIONS:**
- Chat in progress (Golden Path 2 active).
- Hermes sends an approval request.

**USER ACTIONS:**
1. Approval card appears in chat.
2. Tap "Allow" or "Deny" (with scope: once, session, always).

**EXPECTED UI STATE:** Approval card shows title, detail, command, and
choices. Resolving state shown after tap.

**EXPECTED APP STATE:** `SecureRequestSheet` or approval card handles the
response. Response sent through `HermesRPC`.

**EXPECTED BACKEND/HERMES BEHAVIOR:** Gateway receives approval response.
Run continues or stops based on the choice.

**EXPECTED PERSISTENCE:** Approval state recorded in conversation.

**EXPECTED SUCCESS RESULT:** Hermes proceeds with or cancels the action.

**EXPECTED FAILURE BEHAVIOR:**
- Approval arrives while phone locked → Shown when app is opened.
- Network fails during approval → "Couldn't deliver your response."
- Approval expired → Hermes may have moved on.

**RECOVERY BEHAVIOR:** Foreground recovery retrieves pending approvals from
session snapshot.

**PROTECTION:** `conversation-contracts.ts` approval schema,
`HermesRunProtocol.swift` tests, approval recovery tests in iOS.

## Golden Path 4: View and interact with the shared browser

**USER INTENT:** See what page the agent is on and optionally take control.

**PRECONDITIONS:**
- Chat in progress with a browsing agent.
- Chromium installed on the Mac.
- Alice plugin's `browser_live.py` active.

**USER ACTIONS:**
1. Live browser card appears in chat showing the agent's current page.
2. Tap the card to expand to full screen.
3. Take control (type, scroll).
4. Hand back control to the agent.

**EXPECTED UI STATE:** Live JPEG frames of the agent's browser. Pointer
overlay visible. Control lease indicator.

**EXPECTED APP STATE:** `LiveBrowser.swift` displays frames. Control lease
managed by `browser_live.py`.

**EXPECTED BACKEND/HERMES BEHAVIOR:** Plugin follows the agent's tab. Small
JPEG frames sent via long-polling. Control lease enforced server-side.

**EXPECTED PERSISTENCE:** None (ephemeral).

**EXPECTED SUCCESS RESULT:** User sees the page, can interact, and hand back.

**EXPECTED FAILURE BEHAVIOR:**
- No Chromium → Feature unavailable.
- Agent navigates away → View updates.
- Frame timeout → Loading indicator.

**RECOVERY BEHAVIOR:** Re-establish view by tapping the card again.

**PROTECTION:** `test_browser_control.py` plugin tests.

## Golden Path 5: Morning briefing delivery

**USER INTENT:** Receive a morning summary of appointments, reminders, goals,
and Mac health.

**PRECONDITIONS:**
- Hermes cron configured for morning routine.
- Calendar and reminders connected.
- Plugin's `health.py` configured.
- iPhone notifications enabled.

**USER ACTIONS:** None (automatic delivery).

**EXPECTED UI STATE:** Briefing card appears in chat. Sections: today's
appointments, due/overdue reminders, open goals, Mac health, overnight errors.

**EXPECTED APP STATE:** Briefing message added to conversation. Notification
delivered (if app in background).

**EXPECTED BACKEND/HERMES BEHAVIOR:** Hermes cron triggers the morning
routine. Agent collects data from calendar, reminders, goals, health.
Delivers summary through the chat protocol.

**EXPECTED PERSISTENCE:** Briefing saved as a conversation message.

**EXPECTED SUCCESS RESULT:** User sees the briefing when they open Alice.

**EXPECTED FAILURE BEHAVIOR:**
- App suspended → Delivery deferred until app is opened.
- Hermes down → No briefing delivered.
- Calendar access denied → Briefing omits calendar section.

**RECOVERY BEHAVIOR:** Foreground refresh retrieves missed briefings.

**PROTECTION:** Plugin `test_health.py`, `test_calendar.py` tests. Cron
configuration tests.

## Golden Path 6: Create a new agent

**USER INTENT:** Create a new agent with its own profile and conversation.

**PRECONDITIONS:**
- Dashboard connected.
- Agent Maker (Forge) profile available.

**USER ACTIONS:**
1. Agents → Add → New Agent.
2. Describe what the agent should do.
3. Send.

**EXPECTED UI STATE:** New conversation opens. Agent creation in progress.

**EXPECTED APP STATE:** `AgentTaskSession` creates a separate profile session.
`agent_engine.py` mints a new profile via Hermes CLI.

**EXPECTED BACKEND/HERMES BEHAVIOR:** Plugin validates spec, creates profile
(`profile create`), configures model and tools. Session created lazily on
first prompt.

**EXPECTED PERSISTENCE:** Agent conversation saved with its own profile and
session. Appears in Recents.

**EXPECTED SUCCESS RESULT:** New agent conversation is active and usable.

**EXPECTED FAILURE BEHAVIOR:**
- Forge unavailable → Error shown.
- Profile creation fails → Error with recovery info.
- Saved session missing → "This session is no longer on the server."

**RECOVERY BEHAVIOR:** Lost creation response recovered by unique UUID title.
Missing saved session fails visibly rather than redirecting.

**PROTECTION:** `test_agent_engine.py` plugin tests, `AgentTaskSession.swift`
tests.

## Golden Path 7: Pay for a purchase

**USER INTENT:** Complete an online purchase up to and including payment.

**PRECONDITIONS:**
- Chat in progress with a shopping agent.
- Payment card saved in Hermes vault.
- Purchase flow plugin active.

**USER ACTIONS:**
1. Agent searches and presents product options.
2. User selects a product.
3. Agent fills basket, address, delivery.
4. Checkout summary and approval card appear.
5. User taps "Pay."
6. Agent pays on the bank page.
7. Payment outcome shown (confirmed/declined/failed).

**EXPECTED UI STATE:** Product options → basket → checkout summary → payment
approval card → outcome.

**EXPECTED APP STATE:** `PaymentCardOfferCard` handles payment approval.
Purchase flow tracked through plugin's `purchase_flow.py` and `errands.py`.

**EXPECTED BACKEND/HERMES BEHAVIOR:** Plugin validates purchase options.
Payment ledger prevents duplicate payments. Agent fills card via vault.
Bank page (e.g., Redsys) handled by agent.

**EXPECTED PERSISTENCE:** Payment outcome recorded in conversation. Payment
ledger updated.

**EXPECTED SUCCESS RESULT:** Payment confirmed, order number shown.

**EXPECTED FAILURE BEHAVIOR:**
- Card declined → "Payment was declined."
- Payment failed → "Payment failed."
- No card saved → Card form offered via `alice://connect/card`.
- Second payment on same shop → Refused until first outcome known.

**RECOVERY BEHAVIOR:** Approval sent while phone locked returns to chat when
opened.

**PROTECTION:** `test_purchase_flow.py`, `test_errands.py`,
`test_errands_api.py` plugin tests. `PaymentCardOfferCard.swift` tests.

## Golden Path 8: Encrypted conversation sync

**USER INTENT:** Sync conversations across devices with end-to-end encryption.

**PRECONDITIONS:**
- Web companion account created.
- Recovery key generated.
- Second device paired.

**USER ACTIONS:**
1. On device 1: Enable encrypted sync in web settings.
2. Generate recovery key.
3. On device 2: Enter recovery key to import conversations.

**EXPECTED UI STATE:** Sync status indicator. Imported conversations appear.

**EXPECTED APP STATE:** `cloud-sync-runtime.ts` manages sync. Device keys
derived from recovery phrase. Records encrypted before upload.

**EXPECTED BACKEND/HERMES BEHAVIOR:** Server stores only ciphertext and
conflict-resolution metadata. Immutable verifier validates recovery keys.

**EXPECTED PERSISTENCE:** Encrypted records in `alice_sync_record` table.
Pull cursor saved with corresponding state.

**EXPECTED SUCCESS RESULT:** Conversations appear on second device.

**EXPECTED FAILURE BEHAVIOR:**
- Key mismatch → "This recovery key doesn't match."
- Network failure → Retry with backoff.
- Corrupt record → Skipped, other records continue.

**RECOVERY BEHAVIOR:** Re-enter recovery key. Disconnection, retries, and key
mismatch are distinct states.

**PROTECTION:** `cloud-sync-runtime.test.ts`, encrypted sync schema
tests, `0005_sync_verifier.sql` migration.

## Golden Path 9: Reconnect after Hermes restart

**USER INTENT:** Automatically recover the connection after Hermes restarts.

**PRECONDITIONS:**
- Alice was connected.
- Hermes gateway or dashboard was restarted.

**USER ACTIONS:** None (automatic).

**EXPECTED UI STATE:** Connection status shows "Reconnecting…" → "Connected."

**EXPECTED APP STATE:** `HermesConnection` detects disconnection. Retries
connection. Recovers pending questions and approvals from session snapshot.

**EXPECTED BACKEND/HERMES BEHAVIOR:** Gateway becomes available again.
Dashboard responds to auth.

**EXPECTED PERSISTENCE:** Existing conversations preserved. Pending approvals
recovered.

**EXPECTED SUCCESS RESULT:** Alice reconnects without user intervention.

**EXPECTED FAILURE BEHAVIOR:**
- Hermes stays down → "Hermes unreachable" with retry.
- Credentials changed → "The key is not correct."

**RECOVERY BEHAVIOR:** Automatic retry with backoff. Foreground recovery
retrieves pending items.

**PROTECTION:** `hermes-connection.test.ts`, `EventResume.swift` tests,
`HermesRunProtocol.swift` recovery tests.

## Golden Path 10: Build and install on iPhone

**USER INTENT:** Build Alice from source and install on a physical iPhone.

**PRECONDITIONS:**
- Xcode 26, XcodeGen installed.
- Apple Developer account.
- iPhone connected or paired.
- Alice source code.

**USER ACTIONS:**
1. `cd ios && xcodegen generate`
2. `xcodebuild ... build`
3. `xcrun devicectl device install app ...`

**EXPECTED UI STATE:** Alice launches on iPhone.

**EXPECTED APP STATE:** App at the correct build number (monotonic).
`ALICE_SOURCE_REVISION` set to the git commit.

**EXPECTED BACKEND/HERMES BEHAVIOR:** None (build step only).

**EXPECTED PERSISTENCE:** Build artifacts in `ios/.build/`.

**EXPECTED SUCCESS RESULT:** Alice opens on iPhone. Version visible in
Settings.

**EXPECTED FAILURE BEHAVIOR:**
- Signing failure → Check team ID and provisioning.
- Build failure → Check Xcode and Swift versions.
- Install failure → Check device connection and trust.

**RECOVERY BEHAVIOR:** Regenerate project, check signing, retry.

**PROTECTION:** CI runs simulator builds. `scripts/verify-ios.sh build` for
compile check. `scripts/verify-release.mjs` for release verification.

## Protection strategy

| Golden Path | Test type        | Location                                    |
| ----------- | ---------------- | ------------------------------------------- |
| 1. Pairing  | Contract + unit  | `test_plugin_api.py`, `PairingFlow` tests   |
| 2. Chat     | Contract + unit  | `chat-stream.test.ts`, `HermesChatStream`   |
| 3. Approval | Contract + unit  | `conversation-contracts.ts`, iOS tests      |
| 4. Browser  | Unit             | `test_browser_control.py`                   |
| 5. Briefing | Unit             | `test_health.py`, `test_calendar.py`        |
| 6. Agent    | Unit + contract  | `test_agent_engine.py`, `AgentTaskSession`   |
| 7. Payment  | Unit + contract  | `test_purchase_flow.py`, `test_errands.py`  |
| 8. Sync     | Unit + contract  | `cloud-sync-runtime.test.ts`                 |
| 9. Reconnect| Unit             | `hermes-connection.test.ts`, `EventResume`   |
| 10. Build   | CI (simulator)   | `scripts/verify-ios.sh`, quality.yml        |

The cheapest reliable protection is used for each path: unit and contract
tests for most paths, CI simulator builds for the build path, and
fixture-based tests for protocol paths. No slow UI tests are added unless
the path is primarily a UI journey and cannot be verified at a lower level.

## Definition of "Alice fundamentally works"

Alice fundamentally works when all ten Golden Paths succeed:
1. A new iPhone can pair with Hermes.
2. A user can send a message and receive a streaming reply.
3. A user can approve or deny destructive actions.
4. A user can view and interact with the shared browser.
5. Morning briefings are delivered.
6. New agents can be created.
7. Purchases can be completed up to payment.
8. Conversations sync across devices with encryption.
9. Alice reconnects after Hermes restarts.
10. Alice can be built and installed on a physical iPhone.

If any of these paths break, Alice is not fundamentally working, and the
specific failure should be traceable through the test suite to the broken
layer.
