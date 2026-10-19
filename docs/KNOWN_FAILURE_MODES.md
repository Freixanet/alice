# Known Failure Modes

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This catalog is derived from Git history, code analysis, tests, and existing
documentation. Each failure mode includes its root cause, evidence, and
protection.

## 1. Conversation identity corruption

**Failure:** Navigating between chats retargets an in-flight turn, sending
a message to the wrong profile or session.

**Root cause:** The home conversation and bot chats share state if
identity is not carefully preserved. An `@agent` reply carries its own
profile and session on the message.

**Evidence:** `HomeChatSession.swift`, `BotChatSession.swift`,
`ChatTurnRoute.swift`, `AgentTaskSession.swift` all enforce identity
contracts. `AGENTS.md` documents the invariant: "Never silently reroute a
conversation, retry a write against another profile or change its model."

**Protection:** Profile and session are persisted per conversation. The
per-turn watcher records its agent's live questions independently. Recovery
deduplicates by profile and session.

**Status:** Protected by unit tests and architectural contracts.

## 2. Codable backward compatibility break

**Failure:** Extending a persisted model with a new property breaks
decoding of old archives, causing data loss.

**Root cause:** A Swift property default does NOT make synthesized
decoding backward-compatible. `Codable` will fail if the archive doesn't
contain the new key and there's no custom decoding.

**Evidence:** `AGENTS.md`: "Read old Codable archives before extending
persisted models. A Swift property default does not make synthesized
decoding backward-compatible. Never replace an unreadable archive with an
empty one."

**Protection:** `ConversationArchive` reads old blob format and rewrites
in split form. Unreadable bytes retained for recovery. Tests:
`ConversationMigrationTests.swift`, `ConversationArchiveTests.swift`,
`ConversationPersistenceTests.swift`.

**Status:** Protected. Must not be casually refactored.

## 3. Draft loss on navigation

**Failure:** Switching conversations loses the unsent draft text, or a
failed answer's text appears in the wrong chat.

**Root cause:** Drafts were not bound to conversation identity across all
navigation paths. A failed answer could restore its text into the new chat.

**Evidence:** `docs/quality-audit-2026-09-25.md` documents the fixes:
"Draft ownership follows conversation identity across navigation paths."
"Restore failed answers only to their originating conversation."

**Protection:** `ComposerDraftArchive.swift` uses debounced per-chat file
records and a synchronous background save. `ComposerDraftTests.swift`,
`DictationLifecycleTests.swift` cover the regressions.

**Status:** Protected.

## 4. Duplicate payment

**Failure:** A second payment on the same shop is attempted before the
first one's outcome is known.

**Root cause:** No ledger prevented duplicate payment attempts.

**Evidence:** `README.md`: "The plugin keeps a ledger of payments: a
second payment on the same shop is refused until the first one's outcome
is known, and then needs your explicit approval."

**Protection:** `purchase_flow.py` maintains a payment ledger. Errands
start in the plugin, not at the model's discretion. Tests:
`test_purchase_flow.py`.

**Status:** Protected. Real purchases have exposed bugs that have since
been fixed. Not yet reliable enough to leave unattended.

## 5. Errand browsing from chat

**Failure:** The agent starts browsing from the chat instead of from a
proper errand context, or multiple errands run for one request.

**Root cause:** Errands were not properly separated from chat activity.

**Evidence:** Git commit `3882aa3`: "one errand per request, no browsing
from the chat, and cards that sit still." Commit `834c023`: "each errand
browses in its own browser context."

**Protection:** `errands.py` enforces one errand per request. Each errand
gets its own browser context. `ErrandTests.swift`, `test_errands.py`.

**Status:** Protected.

## 6. Stale checkout

**Failure:** A stale checkout is presented as current, or an approved
payment reads as "paying" indefinitely.

**Root cause:** Checkout state was not properly expired or updated.

**Evidence:** Git commit `32ae2d1`: "a stale checkout expires and is
prepared again; approved reads as paying."

**Protection:** `purchase_flow.py` expires stale checkouts. Approval state
is tracked explicitly. Tests: `test_purchase_flow.py`.

**Status:** Protected.

## 7. Model routing error

**Failure:** The same model id is served by multiple providers, and
without tracking the provider, the agent sends an Anthropic model listed
under Nous to OpenRouter, which bills for it and refuses.

**Root cause:** The model picker grouped by provider, but the selected
provider was not persisted alongside the model.

**Evidence:** `AppStore.swift`: `selectedProvider` property with comment
explaining the exact failure. Git commit `50a2203`: "Alice's model changes
in Hermes from her main chat, and says so."

**Protection:** `selectedProvider` persisted in UserDefaults. Model changes
are announced in chat. Tests: `ModelChangeTests.swift`,
`ModelConfigurationTests.swift`, `ModelListTests.swift`.

**Status:** Protected.

## 8. Partial model list

**Failure:** Only `/v1/models` answered with one model, not the full list,
and the picker showed "no models" with no explanation.

**Root cause:** No distinction between "no models" and "partial list."

**Evidence:** `AppStore.swift`: `modelListIsPartial` property.

**Protection:** `modelsError` explains why the list is empty.
`modelListIsPartial` distinguishes partial from complete. Tests:
`ModelListTests.swift`.

**Status:** Protected.

## 9. Hermes unavailable / reconnect

**Failure:** The Hermes gateway or dashboard is unreachable, asleep, or
restarted.

**Root cause:** Network issues, Mac sleeping, or process restarts.

**Evidence:** `HermesClient.swift` `Failure` enum with specific cases:
`.unreachable`, `.timedOut`, `.offline`, `.blockedByPolicy`.
`EventResume.swift` for reconnect. Git commit `131cd1f`: "a reply picks
up where it left off after the socket drops."

**Protection:** `HermesClient.describe()` turns URL-loading errors into
named failures. `EventResume` resumes from last `seq`. Reconnect retries
the connection, not the QR exchange. Sending probes the saved dashboard
connection; if unavailable, the turn fails visibly.

**Status:** Protected. Cannot guarantee always-on delivery while phone is
locked (iOS limitation).

## 10. Unknown Hermes events

**Failure:** A new Hermes version sends event types Alice doesn't
recognize, causing parsing failures or dropped events.

**Root cause:** Hermes evolves independently of Alice.

**Evidence:** `HermesUnknownEvents.swift`, `HermesRunProtocol.swift`.
`AGENTS.md`: "Preserve unknown stream events safely."

**Protection:** Unknown events are preserved safely, not dropped.
Developer → Checks shows "Hermes messages Alice does not understand yet."
Tests: `HermesUnknownEventsTests.swift`, `HermesRunProtocolTests.swift`.

**Status:** Protected.

## 11. Business team message leakage

**Failure:** A Business team agent messages someone outside its channel,
or an external agent messages a Business team member.

**Root cause:** No isolation between agent channels.

**Evidence:** `plugin_api.py` `pre_tool_call` hook on `message_agent`.
`hermes-plugin/README.md` documents the isolation.

**Protection:** The hook checks `ui_meta['alice'].channel`. Business
members can only message teammates. Internal profiles neither send nor
receive. If the rule cannot be checked, the message does not go.
Tests: `test_business_isolation.py`.

**Status:** Protected.

## 12. Egress of secrets after reading outside content

**Failure:** An agent reads a web page (potentially containing prompt
injection), then exfiltrates data or reads secrets via terminal/code.

**Root cause:** No tool-layer guard between reading outside content and
sending data out.

**Evidence:** `egress_guard.py` with documented rationale referencing
Meta's Muse trust model.

**Protection:** Sessions become tainted after reading outside content.
Tainted sessions require approval for egress commands (curl POST, scp,
ssh, etc.) and secrets access (~/.ssh, .env, vault, keychain). The exact
command is shown on the approval card. Tests: `test_egress_guard.py`.

**Status:** Protected.

## 13. Background delivery not arriving

**Failure:** A notification or approval sent while the phone was locked
doesn't arrive until the app is opened.

**Root cause:** iOS controls background execution. No APNs, no push
infrastructure.

**Evidence:** `README.md`: "iOS wakes background apps when it chooses.
When the phone is locked, a notification or approval can wait until you
open the app." `project.yml`: `UIBackgroundModes: [fetch]`.

**Protection:** The notification copy is written to match this — it never
promises delivery while the app is closed. `BGTaskSchedulerPermittedIdentifiers:
com.freixanet.alice.refresh`. Pending approvals come back into the chat
when the app opens.

**Status:** Known limitation. Cannot be fully solved without APNs
infrastructure.

## 14. Card payment failure (Redsys)

**Failure:** Hermes finds card fields by English names and autocomplete
tokens. A Spanish bank page may have neither, so the fill finds nothing
and "Pagar" stays disabled.

**Root cause:** Hermes' vault `browser_vault_fill` relies on English field
names and autocomplete tokens.

**Evidence:** `docs/HANDOFF.md` documents this as an open problem.

**Protection:** Alice shows the live browser view so the person can type
the card manually. The secure card form (`PaymentCardOfferCard`) stores
the card in the vault for future use.

**Status:** Known limitation. **UNKNOWN** whether this is fully resolved.

## 15. Pairing token replay

**Failure:** A pairing token is reused after being claimed.

**Root cause:** The token is a one-time bearer secret.

**Evidence:** `docs/pairing.md` documents the security model.

**Protection:** After `200`, the entry becomes a tombstone (no
credentials). The same token only responds `410 used`. TTL is 5 minutes.
In-memory only (restart invalidates). No redirects on the claim POST.
Same-host validation. Loopback + Tailscale only. No `X-Forwarded-For`
accepted.

**Status:** Protected.

## 16. Rate limit bypass

**Failure:** An attacker bypasses rate limiting by targeting different
serverless instances.

**Root cause:** Serverless instances don't share in-memory state.

**Evidence:** `migrations/0004_security_hardening.sql`: "Constant-space,
cross-instance rate limiting."

**Protection:** `alice_rate_limit` table in Postgres. One row per
(scope, pseudonymous identity). Atomic counter. Burst thresholds protect
auth, client-runtime and Hermes-connection alerts. Cooldown: one minute
per code, route and metric.

**Status:** Protected.

## 17. Sync key mismatch

**Failure:** A recovery key that doesn't match the encrypted verifier is
used, corrupting sync state.

**Root cause:** No server-side verification of recovery key before
accepting it.

**Evidence:** `docs/release-operations.md`: "validate a recovery key
before replacing the saved key or uploading conversations. The account
verifier is immutable."

**Protection:** `migrations/0005_sync_verifier.sql` admits the encrypted
verifier. `sync-crypto.ts` validates the recovery key. Immutable verifier
prevents key substitution. Pull cursor saved with state. Account changes
cancel work from the old account.

**Status:** Protected.

## 18. Duplicate state / concurrent mutations

**Failure:** Multiple views trigger the same read or mutation
concurrently, causing redundant network requests or duplicate effects.

**Root cause:** No deduplication of concurrent operations.

**Evidence:** `docs/request-lifecycle.md`: "Concurrent model reads share
one transport request per account, Hermes connection and profile."
"Alice never automatically retries a mutable Hermes action."

**Protection:** Shared read caches with 30-second TTL. In-flight request
deduplication. Per-subscriber cancellation (last subscriber aborts
transport). No auto-retry for mutations. Idempotency keys where supported.
Tests: `shared-read-cache.test.ts`, `hermes-connection.test.ts`.

**Status:** Protected.

## 19. Streaming delta encoding every conversation

**Failure:** Streaming re-encodes every conversation on every delta,
causing performance issues (e.g., a Radar report in another chat paying
the cost).

**Root cause:** Single-array blob storage required re-encoding all
conversations for any change.

**Evidence:** `ConversationArchive.swift` header comment explains the
history.

**Protection:** Per-chat UserDefaults keys. Only changed chats are encoded
(fingerprint comparison). Old blob still readable, rewritten split on
first save.

**Status:** Protected.

## 20. Attachment bytes rewritten on text edit

**Failure:** A naive persisted draft rewrites image bytes on each text
edit.

**Root cause:** Text and attachments were stored in the same record.

**Evidence:** `docs/quality-audit-2026-09-25.md`: "Text and attachments use
separate records; unchanged attachment bytes are not rewritten."

**Protection:** `ComposerDraftArchive.swift` uses separate records for
text and attachments. Tests: `ComposerDraftTests.swift`.

**Status:** Protected.

## 21. Asynchronous import to wrong chat

**Failure:** An asynchronous photo import appends to whichever chat is now
open, not the one it was started in.

**Root cause:** The picker didn't capture its destination chat.

**Evidence:** `docs/quality-audit-2026-09-25.md`: "The picker captures its
destination; late results remain in the original chat."

**Protection:** Attachment picker captures conversation identity. Late
results go to the original chat. Tests: `ComposerDraftTests.swift`.

**Status:** Protected.

## 22. Dictation callback to wrong chat

**Failure:** Recognition callbacks write into the next chat or restart
after cancellation.

**Root cause:** Dictation session identity was not tracked.

**Evidence:** `docs/quality-audit-2026-09-25.md`: "Cancel pending starts
and reject callbacks from an obsolete dictation session; release only
audio owned by dictation."

**Protection:** `Dictation.swift` cancels pending starts. Obsolete session
callbacks rejected. Audio ownership tracked. Tests:
`DictationLifecycleTests.swift`.

**Status:** Protected.
