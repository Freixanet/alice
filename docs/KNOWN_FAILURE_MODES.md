# Alice — Known Failure Modes and Fragile Areas

What breaks, why, and what must not be casually refactored. Sources: code
comments, `AGENTS.md`, `docs/HANDOFF.md`, `docs/quality-audit-2026-09-25.md`,
`docs/purchases.md`, `docs/verification.md`. **UNKNOWN** marks missing
evidence.

## Fragile areas

1. **Conversation identity and routing.** Home chat = default profile; bot
   chats carry their own profile and canonical session. "Never silently
   reroute a conversation, retry a write against another profile or change
   its model" (`AGENTS.md` Connection identity). The regression that
   motivated this: bot chats used to run on the default profile wearing a
   synthetic directive (`WebSocketBotChatSource.swift` docstring).
2. **Codable archive compatibility.** Swift property defaults do not make
   synthesized decoding backward-compatible; unreadable archives must be
   retained, never replaced with empty ones (`AGENTS.md` Data contract,
   `ConversationArchive.swift`).
3. **Encrypted sync invariants.** Validate a recovery key before replacing
   the saved key or uploading; the account verifier is immutable; pulled
   records and their cursor are saved together; account changes must cancel
   work from the old account (`AGENTS.md` Sync contract).
4. **Hermes stream transparency.** Alice must not filter tools, models,
   events; unknown stream events must be preserved safely
   (`docs/hermes-contracts.md`, `HermesUnknownEvents.swift`).
5. **The pay gate.** No card fill or paying click before the person's
   approval of the exact checkout; the payment ledger refuses a second
   payment whose first outcome is unknown (`errands.py`).
6. **The egress/outbound guards.** Origin validation before attaching
   secrets; redirect protections; private-hostname rejection
   (`AGENTS.md` Credentials; `outbound-http.server.ts`; `egress_guard.py`).
7. **The pairing token seam.** Only the claim route is opted into token
   auth; Hermes' public path list is untouched (`plugin_api.py`). Changing
   this could expose or break dashboard auth.
8. **`AppStore.swift` size.** A known-large coordinator — new behavior must
   go to focused modules; extractions require regression coverage; "do not
   split files just to hide coupling" (`AGENTS.md` Maintainable).
9. **The development Mac.** No simulators on purpose; do not download
   simulator runtimes or run `verify-ios.sh` there (`AGENTS.md` This Mac).
10. **The shared agent browser on the dev Mac** (CDP 127.0.0.1:9222) is the
    person's live session — never used for tests (`AGENTS.md`).

## Failure modes

| # | Failure mode | Symptom | Root cause | Where |
| - | --- | --- | --- | --- |
| 1 | Card fill silently does nothing | Payment page's pay button stays disabled | Hermes finds card fields by English names/autocomplete tokens; Spanish bank pages may have neither | `docs/HANDOFF.md` open problem 1; `vault_cards.py` |
| 2 | Live view is a slideshow | Choppy frames | JPEG frames over long-polling, by design today | `browser_live.py`; `docs/HANDOFF.md` problem 2 |
| 3 | No push while app closed | Missed answers | iOS suspends the app; no APNs; only Bark/routine delivery exists | `mac/notifier/alice_notifier.py`; `docs/proactive.md` |
| 4 | Pairing QR dead | 410/401/404 on claim | One-time token consumed/expired, or dashboard restarted (in-memory store) | `docs/pairing.md` §4 |
| 5 | Wrong provider billed / refusal | Model routed to provider that does not serve it | Same model id under multiple providers; picker must record the provider | `AppStore.swift` comments |
| 6 | Purchase resumes unannounced in chat | Old purchase resurfacing after an unrelated question | Goal judged on the chat's own session — fixed by moving purchases to their own errand session; do not regress | `errands.py` docstring |
| 7 | Double payment | Second charge on same shop | Mitigated by the payment ledger — refuses a second payment until the first outcome is known; requires explicit approval after | `errands.py`; `docs/purchases.md` |
| 8 | Draft loss / cross-chat draft bleed | Text appears in wrong chat or lost | Historically: drafts not owned by conversation identity; fixed via per-chat debounced records and synchronous background save — keep those invariants | `docs/quality-audit-2026-09-25.md` |
| 9 | Image bytes rewritten on each keystroke | Storage churn | Fixed by separating text and attachment draft records | `docs/quality-audit-2026-09-25.md` |
| 10 | Redraw storms | Whole shell redraws per streamed token | Views depending on the whole conversation array — fixed by `ActiveChat`/`shownConversation` split; keep views off `conversations` | `AppStore.swift` comments |
| 11 | Missed interim assistant messages | Reply appears only at the end | Server config `display.interim_assistant_messages: false` — server never emits `message.interim` | `docs/plan-2026-09-20-backlog.md` bug 15 |
| 12 | Plugin changes have no effect | New tab features missing | Hermes loads plugins once per process — gateway and dashboard must be restarted | [README.md](../README.md) step 1 |
| 13 | Missed question/approval | Pending request invisible | Approvals live on the session that asked; recovery deduplicates by profile+session; quiet-turn snapshots retain open requests | `AGENTS.md` Connection identity; `RoutineQuietRuns.swift` |
| 14 | Wrong "models empty" conclusion | User stuck at empty picker | Absence vs failed detection vs partial list must be distinguished (`modelsError`, `modelListIsPartial`) | `AppStore.swift`; `AGENTS.md` |
| 15 | Lost agent-task creation response | Orphaned profile | Recovered by unique UUID title; a missing saved session must fail, not redirect or replay work | `AgentTaskSession.swift` |
| 16 | Partial sync / key mismatch | Sync appears off | Distinct states: disconnection, retries, key mismatch — not one boolean | `AGENTS.md` Sync contract |
| 17 | Direct web mode key exposure | Key readable by JavaScript | By design — "do not promise otherwise"; threat documented | `AGENTS.md`; `SECURITY.md` |
| 18 | Directory rename of an agent profile | Orphaned sessions | Sessions keep `registry_home` on the old path; Hermes has no coordination outside it — Alice refuses to start such renames | `agent_engine.py`; ARCHITECTURE.md §6 |
| 19 | Purchase flow over-trusts the model | Bad options shown | Mitigated: `purchase_options` validates https page, stock, price, currency; the app loads only the plugin-accepted list; visual verification still depends on the model | `purchase_flow.py`; `docs/purchases.md` |
| 20 | Live contract check false positives | — | Fixture tests do not establish live model outcomes; keep fixture vs live evidence distinct | `AGENTS.md` Verification |

## Diagnosis pointers

See [DEBUGGING.md](DEBUGGING.md) for the symptom → diagnosis table; each row
above names its own evidence file. The phone's Developer Checks
(`DiagnosticChecks.swift`) is the fastest triage for reachability, plugin
presence, notifications, routines and freezes.

## Things that MUST NOT be casually refactored

From `AGENTS.md` "Contracts that must survive changes", plus code comments:

1. **Connection identity** — never reroute conversations across profiles,
   retry writes against another profile, or change a chat's model silently.
2. **Credentials** — validate origins before attaching secrets; keep
   redirect protections; Keychain on iOS; never promise direct web mode is
   key-safe.
3. **Data** — read old Codable archives before extending persisted models;
   never replace an unreadable archive with an empty one; persist user
   edits.
4. **Synchronization** — validate recovery keys before replacement or
   upload; immutable account verifier; records saved with their cursor;
   account changes cancel old-account work.
5. **Hermes contracts** — versioned official sources, detected
   capabilities, unknown stream events preserved; management endpoint may
   be separate from the chat API; "Unsupported ≠ empty ≠ offline ≠
   unauthorized".
6. **User experience** — destructive actions name their target; never claim
   completion before the remote operation succeeds.
7. **Notifications** — distinguish answer / routine delivery / failure /
   approval; never promise always-on background delivery.
8. **The multimodal turn wrapper** — `/v1/runs` overloads top-level arrays
   as message lists; parts arrays must stay wrapped in an explicit user
   message (`HermesChatStream.swift`).
9. **The pay gate and payment ledger** — any relaxation reintroduces
   double-payment risk.
10. **`WebSocketBotChatSource` session resolution** — always take the
    server's `canonical_session`/`resolved_id`; never scan transcripts or
    carry a session pointer that can go stale.
11. **The `verify-ios.sh` simulator discipline** — the "Alice Verification"
    simulator only; never auto-select a developer's simulator.
12. **Generated-file policy** — never commit `Alice.xcodeproj`, credentials,
    build outputs or local data (`AGENTS.md`).
13. **Test-environment separation** — never test against the person's real
    Hermes, shared browser, or real purchases; read-only live contract
    checks must be explicitly marked.
14. **`AppStore.swift` boundaries** — grow it no further; extract only with
    regression coverage, not to hide coupling.
15. **Build-number monotonicity** — `CURRENT_PROJECT_VERSION` only ever
    rises, passed on the command line, never fixed in `project.yml`.

## Open problems at last handoff (24 Sep 2026, `docs/HANDOFF.md`)

1. Card payment (Redsys) fixed but not yet proven end to end; fallback is
   the person typing the card in the live view.
2. Live view is a slideshow — WebSocket or WebRTC needed for real video.
3. Remaining product brief items (status snippet, proactivity setting,
   Ideas tab, personalization beyond the hard-coded "Marcos" persona,
   chat bubbles).
4. Gmail not yet connected.

Status of each item after 24 September 2026: **UNKNOWN** from repository
evidence alone — check recent commits and `docs/quality-audit-2026-09-25.md`
for later fixes.
