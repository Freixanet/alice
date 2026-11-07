# Failure Learnings

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`
>
> This document turns Alice's historical failures into permanent
> protections. Each entry reconstructs the observed failure, identifies the
> root cause, determines the missing invariant, and establishes the
> cheapest permanent protection.
>
> Repeated bugs are generalized into useful invariants. This is not a
> one-test-per-bug list.

## Learning 1: Conversation identity must be bound to the message, not the view

**OBSERVED FAILURE**
Navigating between chats could retarget an in-flight turn, sending a
message to the wrong profile or session. A failed answer's text could be
restored into the wrong chat. An `@agent` reply could lose its profile
identity.

**EVIDENCE/COMMITS**
- `AGENTS.md` contracts section: "Connection identity"
- `docs/quality-audit-2026-09-25.md`: draft ownership and failed answer
  restoration fixes
- `HomeChatSession.swift`, `BotChatSession.swift`,
  `AgentTaskSession.swift` enforce identity
- Multiple fix commits in the 700+ history for chat routing

**ROOT CAUSE**
Identity was not consistently bound to the conversation at the point of
creation. Views could change the active conversation while a turn was in
flight.

**GENERAL FAILURE CLASS**
State ownership: the view layer must not own conversation identity. The
session must carry its own identity.

**MISSING INVARIANT**
Every turn (message, retry, approval, question) must retain the profile
and session of the conversation that originated it, regardless of what
the user navigates to.

**PERMANENT PROTECTION**
- Architectural contract (see [ARCHITECTURE_CONTRACTS.md](ARCHITECTURE_CONTRACTS.md)
  Contract 1).
- Unit tests: `HomeChatSessionTests`, `BotChatSessionTests`,
  `AgentTaskSessionTests`, `ChatTurnRouteTests`.
- Draft archive uses per-chat file records.

**HOW PROTECTION IS VERIFIED**
Unit tests exercise identity preservation across navigation, retry, and
recovery. Draft tests verify per-chat isolation.

---

## Learning 2: Codable defaults are not backward-compatible

**OBSERVED FAILURE**
Adding a new property to a persisted model with a default value would
break decoding of old archives, causing data loss.

**EVIDENCE/COMMITS**
- `AGENTS.md`: "A Swift property default does not make synthesized
  decoding backward-compatible."
- `ConversationArchive.swift`: old blob → split migration logic
- `ConversationMigrationTests.swift`

**ROOT CAUSE**
Swift's synthesized `Codable` does not use default values for missing
keys. If the archive doesn't contain the new key, decoding fails.

**GENERAL FAILURE CLASS**
Persistence: extending persisted models requires explicit backward
compatibility.

**MISSING INVARIANT**
Any new `Codable` property on a persisted model must either be truly
optional with `decodeIfPresent`, or have a custom `init(from decoder:)`
that handles missing keys.

**PERMANENT PROTECTION**
- Architectural contract (see [ARCHITECTURE_CONTRACTS.md](ARCHITECTURE_CONTRACTS.md)
  Contract 3).
- `ConversationMigrationTests` test old format compatibility.
- `AGENTS.md` documents the rule explicitly.
- Unreadable archives are retained, never replaced with empty ones.

**HOW PROTECTION IS VERIFIED**
Migration tests decode old archive fixtures with current models. Unit
tests verify unreadable bytes are retained.

---

## Learning 3: Drafts must follow conversation identity, not view state

**OBSERVED FAILURE**
Switching conversations lost unsent draft text. A failed answer's text
appeared in the wrong chat. Closing the app while writing lost the draft.
An asynchronous photo import appended to whichever chat was now open.

**EVIDENCE/COMMITS**
- `docs/quality-audit-2026-09-25.md`: documents 9 draft-related fixes
- `ComposerDraftArchive.swift`: per-chat file records
- Commits for draft ownership, background save, attachment separation

**ROOT CAUSE**
Drafts were not bound to conversation identity. They were stored in view
state, which changed when the user navigated.

**GENERAL FAILURE CLASS**
State ownership: transient user input must be persisted per-conversation,
not per-view.

**MISSING INVARIANT**
Drafts (text, attachments, mentions) belong to the conversation they were
written in. Navigation, app suspension, or async completion must not move
them to another conversation.

**PERMANENT PROTECTION**
- `ComposerDraftArchive.swift`: debounced per-chat file records.
- Synchronous background save.
- Text and attachments use separate records (no rewriting bytes on text
  edit).
- Attachment picker captures its destination chat.
- Failed answers restore only to their originating conversation.
- Dictation callbacks from obsolete sessions are rejected.
- Tests: `ComposerDraftTests`, `DictationLifecycleTests`.

**HOW PROTECTION IS VERIFIED**
Unit tests cover all navigation paths, app suspension, async completion,
and cancellation.

---

## Learning 4: Errands must be owned by the plugin, not the model

**OBSERVED FAILURE**
The agent started browsing from the chat instead of from a proper errand
context. Multiple errands ran for one request. Cards moved around. A
checkout was presented as current when it was stale.

**EVIDENCE/COMMITS**
- Commit `36d8810`: "a purchase request starts its errand in the plugin,
  not at the model's discretion"
- Commit `3882aa3`: "one errand per request, no browsing from the chat"
- Commit `834c023`: "each errand browses in its own browser context"
- Commit `32ae2d1`: "a stale checkout expires and is prepared again"

**ROOT CAUSE**
Errand lifecycle was not deterministically controlled. The model could
start browsing whenever it wanted, leading to duplicate errands and stale
state.

**GENERAL FAILURE CLASS**
Ownership: side-effecting operations must be initiated by deterministic
code, not by model discretion.

**MISSING INVARIANT**
An errand (which drives a browser, fills a basket, and may result in a
payment) must be started by the plugin, scoped to one per request, and
have its own browser context. Checkout state must be explicitly tracked
and expired.

**PERMANENT PROTECTION**
- `errands.py`: one errand per request.
- `purchase_flow.py`: errand starts in the plugin, checkout state tracked.
- Each errand gets its own browser context.
- Stale checkouts expire.
- Payment ledger prevents duplicate payments.
- Tests: `test_errands.py`, `test_purchase_flow.py`,
  `test_errand_hooks.py`, `test_errands_api.py`.

**HOW PROTECTION IS VERIFIED**
Plugin tests verify one-errand-per-request, browser context isolation,
checkout expiry, and payment ledger.

---

## Learning 5: Model routing must track the provider, not just the model ID

**OBSERVED FAILURE**
The same model ID is often served by multiple providers. Without tracking
the selected provider, an Anthropic model listed under Nous was sent to
OpenRouter, which billed for it and refused.

**EVIDENCE/COMMITS**
- `AppStore.swift`: `selectedProvider` property with explanatory comment
- Commit `50a2203`: "Alice's model changes in Hermes from her main chat"

**ROOT CAUSE**
The model picker grouped by provider, but the selected provider was not
persisted alongside the model.

**GENERAL FAILURE CLASS**
State: when an entity has multiple dimensions (model + provider), all
dimensions must be persisted together.

**MISSING INVARIANT**
A model selection includes both the model ID and the provider under which
it was selected. Both are persisted and sent together.

**PERMANENT PROTECTION**
- `AppStore.swift`: `selectedProvider` persisted in UserDefaults.
- Model changes announced in chat.
- Tests: `ModelChangeTests`, `ModelConfigurationTests`, `ModelListTests`,
  `BotModelChoiceTests`, `BotModelFollowTests`.

**HOW PROTECTION IS VERIFIED**
Unit tests verify provider is persisted and sent with model changes.

---

## Learning 6: After reading outside content, egress must require approval

**OBSERVED FAILURE**
An agent reads a web page (potentially containing prompt injection), then
exfiltrates data or reads secrets via terminal/code without the user
knowing.

**EVIDENCE/COMMITS**
- `egress_guard.py`: implemented with documented rationale referencing
  Meta's Muse trust model
- `test_egress_guard.py`: tests

**ROOT CAUSE**
No tool-layer guard between reading outside content and sending data out.

**GENERAL FAILURE CLASS**
Security: trust must be re-evaluated after a session reads untrusted
content.

**MISSING INVARIANT**
After reading outside content, a session is tainted. In a tainted session,
commands that could send data out or read secrets require user approval.
The exact command is shown.

**PERMANENT PROTECTION**
- `egress_guard.py`: `observe()`, `tainted()`, `risk()` functions.
- 6-hour TTL on taint.
- Regex patterns for egress (curl POST, scp, ssh, etc.) and secrets
  (~/.ssh, .env, vault, keychain).
- `pre_tool_call` hook in Hermes.
- Tests: `test_egress_guard.py`.

**HOW PROTECTION IS VERIFIED**
Plugin tests verify taint propagation, egress detection, and secrets
detection.

---

## Learning 7: Business team agents must only talk among themselves

**OBSERVED FAILURE**
Without isolation, any agent could message Business team members, and
Business team members could message external agents.

**EVIDENCE/COMMITS**
- `plugin_api.py`: `pre_tool_call` hook on `message_agent`
- `hermes-agents/business-team/instalar.py`: sets channel metadata
- `test_business_isolation.py`: tests

**ROOT CAUSE**
No channel-scoped messaging isolation.

**GENERAL FAILURE CLASS**
Security: agents in a sensitive channel must be isolated from general
agent traffic.

**MISSING INVARIANT**
Business team agents can only message teammates in their channel. External
agents cannot message Business members. Internal profiles neither send nor
receive. If the rule cannot be checked, the message does not go.

**PERMANENT PROTECTION**
- `pre_tool_call` hook checks `ui_meta['alice'].channel`.
- Prompt section (`alice.equipos`) tells agents who they may message.
- Internal profiles (`ui_meta['alice'].internal`) are excluded.
- Tests: `test_business_isolation.py`.

**HOW PROTECTION IS VERIFIED**
Plugin tests verify channel isolation, external blocking, and internal
exclusion.

---

## Learning 8: Pairing tokens must be one-time, short-lived, and network-restricted

**OBSERVED FAILURE**
Without proper token lifecycle, a pairing token could be replayed, used
from an unauthorized network, or stolen via redirects.

**EVIDENCE/COMMITS**
- `docs/pairing.md`: full security model documentation
- `plugin_api.py`: `PairingCodeProvider`, offer storage, claim handler
- `PairingClient.swift`, `PairingPayload.swift`: iOS client validation

**ROOT CAUSE**
A bearer token that delivers gateway credentials needs strong lifecycle
controls.

**GENERAL FAILURE CLASS**
Security: bearer tokens must have TTL, one-time use, network restriction,
and no redirect following.

**MISSING INVARIANT**
Pairing tokens are one-time (tombstone after use), 5-minute TTL,
loopback + Tailscale only (peer address, not headers), no redirects,
no persistence (in-memory only), no secrets in logs, Cache-Control:
no-store.

**PERMANENT PROTECTION**
- `PairingCodeProvider` in `plugin_api.py`.
- `PairingPayload.swift` validates response (same-host, no embedded
  credentials, HTTPS doesn't degrade to HTTP).
- `HermesAddress.swift` validates gateway URL policy.
- Tests: `PairingClientTests`, `PairingPayloadTests`,
  `ConnectionAddressSecurityTests`.

**HOW PROTECTION IS VERIFIED**
Unit tests verify token lifecycle, same-host validation, and no-redirect
behavior. Gitleaks scans for secrets.

---

## Learning 9: Reads and mutations need different retry semantics

**OBSERVED FAILURE**
Without distinguishing reads from mutations, a failed mutation could be
silently retried, repeating an external effect (sending a message twice,
paying twice).

**EVIDENCE/COMMITS**
- `docs/request-lifecycle.md`: documents the contract
- `shared-read-cache.ts`: read deduplication with 30-second TTL
- `hermes-transport.ts`, `hermes-connection.ts`: transport handling

**ROOT CAUSE**
No distinction between idempotent reads and side-effecting mutations in
retry logic.

**GENERAL FAILURE CLASS**
Networking: idempotent operations may be retried; side-effecting
operations must not be auto-retried.

**MISSING INVARIANT**
Reads may be deduplicated and cached (30-second TTL, failures never
cached). Mutations are never auto-retried. Idempotency keys are used where
supported. Account changes, reconnection, and mutations invalidate caches.

**PERMANENT PROTECTION**
- `shared-read-cache.ts`: per-account/connection/profile deduplication.
- `hermes-transport.ts`: no auto-retry for mutations.
- `abortable-delay.ts`: polling delays removed on abort.
- Sync checks cancellation between key derivation, encryption, network,
  and decryption.
- Tests: `shared-read-cache.test.ts`, `hermes-connection.test.ts`,
  `abortable-delay.test.ts`.

**HOW PROTECTION IS VERIFIED**
Unit tests exercise deduplication, per-subscriber cancellation,
last-subscriber transport abort, failed-value exclusion, invalidation,
account isolation, and pre-network sync cancellation.

---

## Learning 10: Per-chat storage prevents redundant encoding

**OBSERVED FAILURE**
Streaming re-encoded every conversation on every delta. A Radar report
sitting in another chat paid that cost. Performance suffered.

**EVIDENCE/COMMITS**
- `ConversationArchive.swift`: header comment explains the history
- Per-chat UserDefaults keys with fingerprint comparison

**ROOT CAUSE**
Single-array blob storage required re-encoding all conversations for any
change to any one.

**GENERAL FAILURE CLASS**
Performance: persistence should be proportional to the change, not to the
total state.

**MISSING INVARIANT**
Each conversation is stored under its own key. Only changed chats are
encoded (fingerprint comparison). Old formats are still readable and
rewritten on first save.

**PERMANENT PROTECTION**
- `ConversationArchive.swift`: per-chat keys, fingerprint comparison,
  `PreparedWrite` off main thread.
- Old blob format still read on launch, rewritten split.
- Unreadable bytes retained.
- Tests: `ConversationArchiveTests`, `ConversationPersistenceTests`.

**HOW PROTECTION IS VERIFIED**
Unit tests verify per-chat encoding, fingerprint comparison, old format
migration, and unreadable archive retention.

---

## Summary: generalized invariants

From the above learnings, these invariants should guide all future work:

1. **Identity follows the entity, not the view.** Conversations, drafts,
   turns, and tasks carry their own identity.
2. **Persistence must be backward-compatible.** Codable defaults don't
   count. Old formats are still read. Unreadable data is retained.
3. **Side-effecting operations are initiated by deterministic code, not
   model discretion.** Errands, payments, and profile changes start in the
   plugin.
4. **Trust is re-evaluated after reading untrusted content.** Tainted
   sessions require approval for egress.
5. **Bearer tokens have strong lifecycle controls.** TTL, one-time use,
   network restriction, no redirects.
6. **Reads and mutations have different retry semantics.** Reads
   deduplicate and cache. Mutations never auto-retry.
7. **Persistence is proportional to the change.** Only changed state is
   encoded.
8. **All dimensions of a selection are persisted together.** Model +
   provider, not just model.
9. **Channel isolation is enforced at the tool layer.** Business team
   members only talk among themselves.
10. **Unknown data is preserved, not dropped.** Unknown Hermes events are
    stored safely.
