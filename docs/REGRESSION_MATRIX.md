# Regression Matrix

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This matrix identifies behaviors whose failure would cause the greatest
user-visible, data-integrity, or architectural damage, and the cheapest
reliable protection for each.

The objective is **maximum real confidence / minimum testing cost**.

## Critical behavior matrix

| Behavior | Failure impact | Current coverage | Historical evidence | Best protection level | Fixtures/dependencies | Exec cost | Implemented protection |
|----------|---------------|-----------------|---------------------|----------------------|----------------------|-----------|----------------------|
| Conversation identity preservation | Critical — messages to wrong agent | Unit tests | Git history, AGENTS.md contracts | Unit | Mock transport | <1s | `HomeChatSessionTests`, `BotChatSessionTests`, `AgentTaskSessionTests`, `ChatTurnRouteTests` |
| Codable backward compatibility | Critical — data loss | Unit tests | AGENTS.md, ConversationArchive | Unit | Old archive fixtures | <1s | `ConversationMigrationTests`, `ConversationArchiveTests`, `ConversationPersistenceTests` |
| Draft persistence across navigation | High — lost user input | Unit tests | quality-audit-2026-09-25 | Unit | Mock storage | <1s | `ComposerDraftTests` |
| Dictation lifecycle | High — text in wrong chat | Unit tests | quality-audit-2026-09-25 | Unit | Mock speech | <1s | `DictationLifecycleTests` |
| Streaming text assembly | High — garbled replies | Unit tests | Git commits for streaming | Unit | Mock stream | <1s | `StreamingTextTests`, `StreamWinnerTests` |
| Event resume by seq | High — missed events | Unit tests | commit `131cd1f` | Unit | Mock events | <1s | `EventResumeTests` |
| Model routing (provider tracking) | High — wrong provider billed | Unit tests | AppStore.swift comment | Unit | Mock models | <1s | `ModelChangeTests`, `ModelConfigurationTests`, `ModelListTests` |
| Purchase flow (one errand per request) | High — duplicate charges | Unit + plugin tests | commits `3882aa3`, `36d8810` | Unit + integration | Mock Hermes CLI | <2s | `PurchaseFlowTests`, `test_purchase_flow.py`, `test_errands.py` |
| Payment ledger (no duplicate payment) | Critical — double charge | Plugin tests | README.md ledger | Unit | Mock store | <1s | `test_purchase_flow.py` |
| Egress guard (tainted session) | Critical — data exfiltration | Plugin tests | egress_guard.py | Unit | Mock session | <1s | `test_egress_guard.py` |
| Business team isolation | Critical — message leakage | Plugin tests | plugin_api.py hook | Unit | Mock profiles | <1s | `test_business_isolation.py` |
| Pairing token one-time use | Critical — token replay | Unit tests | docs/pairing.md | Unit | Mock server | <1s | `PairingClientTests`, `PairingPayloadTests` |
| Unknown Hermes event preservation | Medium — silent data loss | Unit tests | HermesUnknownEvents | Unit | Synthetic events | <1s | `HermesUnknownEventsTests`, `HermesRunProtocolTests` |
| Bot chat delivery | High — missed messages | Unit tests | Git history | Unit | Mock transport | <1s | `BotChatDeliveryTests`, `BotChatSessionTests` |
| Bot model choice | Medium — wrong model | Unit tests | commit `493c675` | Unit | Mock models | <1s | `BotModelChoiceTests`, `BotModelFollowTests` |
| Notification routing | Medium — wrong notification type | Unit tests | EventDigest, NotificationRouting | Unit | Mock events | <1s | `NotificationTruthTests`, `NotificationLinkTests` |
| App lock / biometrics | High — unauthorized access | Unit tests | AppLock.swift | Unit | Mock biometrics | <1s | `AppLockTests` |
| Secure request handling | Critical — secret leakage | Unit tests | SecureRequestSheet | Unit | Mock requests | <1s | `SecureRequestTests`, `SecretKeyCardTests` |
| Place trigger lifecycle | Medium — missed trigger | Unit tests | PlaceWatcher | Unit | Mock location | <1s | `PlaceTriggerTests` |
| Errand transcript | Medium — lost errand state | Unit tests | ErrandTranscript | Unit | Mock errands | <1s | `ErrandTranscriptTests` |
| Conversation title | Low — cosmetic | Unit tests | ConversationTitle | Unit | Mock conversations | <1s | `ConversationTitleTests` |
| Haptic vocabulary | Low — wrong feedback | Unit tests | Haptics.swift | Unit | None | <1s | `HapticTests` |
| Agenda reminder parsing | Medium — wrong date | Unit tests | AgendaRows | Unit | Mock reminders | <1s | `AgendaTests`, `BriefingRemindersTests` |
| Calendar change detection | Medium — stale events | Unit tests | CalendarSync | Unit | Mock calendar | <1s | `CalendarChangeTests` |
| Health sync | Medium — missing health data | Unit tests | HealthSync | Unit | Mock HealthKit | <1s | (existing tests) |
| Sync crypto | Critical — data corruption | Unit tests | sync-crypto.ts | Unit + property-based | Synthetic data | <5s | `sync-crypto.test.ts`, `sync-merge.test.ts` |
| Sync runtime client | High — sync failure | Unit tests | sync-runtime-client.ts | Unit | Mock server | <2s | `sync-runtime-client.test.ts` |
| Chat stream state machine | High — garbled messages | Unit tests | chat-stream.ts | Unit | Mock stream | <1s | `chat-stream.test.ts`, `chat-stream-fallback.test.ts` |
| Hermes connection state | High — false connected/disconnected | Unit tests | hermes-connection.ts | Unit | Mock connection | <1s | `hermes-connection.test.ts` |
| Shared read cache | Medium — stale data | Unit tests | shared-read-cache.ts | Unit | Mock cache | <1s | `shared-read-cache.test.ts` |
| Message patch (incremental) | High — corrupted messages | Unit tests | message-patch.ts | Unit | Mock messages | <1s | `message-patch.test.ts` |
| Rate limiting | High — abuse | Unit + integration | rate-limit.server.ts | Unit + integration | Mock DB | <2s | `rate-limit.server.test.ts`, `rate-limit.integration.test.ts` |
| Agent engine (create/rename) | Critical — profile corruption | Plugin tests | agent_engine.py | Unit | Mock Hermes CLI | <2s | `test_agent_engine.py` |
| Memory keeper (cleanup) | High — lost memory | Plugin tests | memory_keeper.py | Unit | Mock memory | <1s | `test_memory_keeper.py` |
| Memory review (fact extraction) | Medium — wrong facts | Plugin tests | memory_review.py | Unit | Mock conversation | <1s | `test_memory_review.py` |
| Vault OTP | High — OTP exposure | Plugin tests | vault_otp.py | Unit | Mock vault | <1s | `test_vault_otp.py` |
| Secret store | Critical — secret leakage | Plugin tests | secret_store.py | Unit | Mock env | <1s | `test_secret_store.py` |
| Text channel (Telegram/iMessage) | Medium — message routing | Plugin tests | text_channel.py | Unit | Mock channel | <1s | `test_text_channel.py` |
| Browser control | Medium — browser failure | Plugin tests | browser_live.py | Unit | Mock browser | <1s | `test_browser_control.py` |

## Recommended additional protections

### High-value, low-cost additions

1. **Property-based test for Codable round-trip** — generate random
   conversation structures, encode, decode, verify equality. Catches
   backward compatibility breaks automatically. Use `fast-check` (web) or
   Swift Testing's property-based features.

2. **Contract test for Hermes event seq resume** — generate a stream with
   gaps, verify `EventResume` requests the right range. Catches off-by-one
   errors in seq tracking.

3. **Integration test for pairing token lifecycle** — mint, claim, attempt
   replay, verify `410`. Catches token reuse bugs.

4. **Fuzz test for egress guard regex** — generate random commands, verify
   no false negatives (dangerous commands that pass) and acceptable false
   positive rate.

### Redundant or brittle tests (documented, not removed)

- **`SymbolNameTests.swift`** — tests SF Symbol name constants. Low value
  but harmless. Remove only if maintenance cost becomes non-trivial.
- **`ReplyButtonWrapTests.swift`** — tests button wrapping layout. Brittle
  to layout changes. Consider replacing with a visual review screenshot.
- **`StatusCaptionTests.swift`** — tests status caption text. Implementation
  detail. Low confidence per cost.

### Tests of implementation details (documented)

- **`BotPlacementTests.swift`** — tests bot placement in lists. If the list
  implementation changes, this test breaks without a behavioral change.
- **`BotSectionTests.swift`** — tests section grouping. Same concern.
- **`HomeShortcutTests.swift`** — tests shortcut configuration. If shortcut
  model changes, test breaks.

These tests are not wrong — they provide some confidence. But they are
brittle and should be replaced with behavior-focused tests when they next
break.

## Navigation journeys (UI tests)

| Journey | What it proves | Cost | Status |
|---------|---------------|------|--------|
| `NavigationJourneyTests` | Main destinations reachable | ~2 min | Implemented |
| `BotNavigationTests` | Bot chat navigation | ~1 min | Implemented |
| `HomeKeyboardStabilityTests` | Keyboard interactions | ~1 min | Implemented |
| `EverydayVisualReviewTests` | Visual screenshots | ~2 min | Implemented |
| `DocumentationScreenshotsTests` | Doc screenshots | ~1 min | Implemented |
| `AgentTaskJourneyTests` | Agent task flow | ~2 min | Implemented |
| `ActivityFixConfirmationTests` | Activity confirmation | ~1 min | Implemented |
| `ExperimentalHomeMenuTests` | Experimental UI | ~1 min | Implemented |

UI tests are the most expensive and should only protect behaviors that
cannot be tested at a lower level: navigation reachability, keyboard
interactions, and visual review.

## Performance benchmarks

| Benchmark | What it measures | Cost | Status |
|-----------|-----------------|------|--------|
| `EverydayPerformanceTests` | Launch, scroll, navigation | ~10 min | Implemented (CI only) |

Performance benchmarks are isolated in `AlicePerformanceTests` and run
only when the harness changes. They do not run on every PR.
