# Alice: reliability, usability and capability audit

Reviewed on 25 September 2026, starting at `920e3f7`. This is an evidence ledger,
not a claim that every feature works, that Alice is infallible, or that it outperforms
all competing products. Public product descriptions establish advertised capability;
they do not establish comparative reliability or quality.

## Confirmed defects addressed

| User journey                                             | Failure found in the code                                                          | Change and regression evidence                                                                                       |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Start a new chat                                         | Text cleared but the previous chat's attachments stayed in the composer            | Switching conversation identity saves and restores the entire draft; a new chat starts empty                         |
| Open a result, notification or agent                     | Only drawer navigation saved drafts; other routes could move text between agents   | Draft ownership follows conversation identity across navigation paths                                                |
| Close Alice while writing                                | The active draft was not saved; attachment and mention drafts were never durable   | Debounced per-chat file records and a synchronous background save; reopening restores text, mentions and files       |
| Type with an attachment                                  | A naive persisted draft would rewrite image bytes on each text edit                | Text and attachments use separate records; unchanged attachment bytes are not rewritten                              |
| Edit a sent message, then cancel                         | The previously unsent text was replaced and lost                                   | Keep the unsent draft while editing and restore it on cancellation or navigation                                     |
| Import a photo, then switch chats                        | The asynchronous import appended to whichever chat was now open                    | The picker captures its destination; late results remain in the original chat                                        |
| Answer a question, then switch chats                     | A failed answer could restore its text into the new chat                           | Restore failed answers only to their originating conversation, without overwriting newer text                        |
| Dictate, then leave the chat or cancel during permission | Recognition callbacks could write into the next chat or restart after cancellation | Cancel pending starts and reject callbacks from an obsolete dictation session; release only audio owned by dictation |
| Check Recents after a reply changes                      | Shelf membership caches retained old message snapshots                             | Attention reads current messages; regression covers approval arrival and resolution without a shelf change           |

Tests: `ComposerDraftTests`, `DictationLifecycleTests`, existing `ChatAttentionTests`.
The draft archive preserves unreadable records and reports failed writes. Attachments
use the existing conversation file store, not the preferences plist. Existing
text-only drafts remain readable and migrate after a successful save.

The actual dark screenshots also exposed white text on the near-white prominent
Connect button. Home and receipt actions now use a contrasting foreground for
the selected scheme. The screenshot fixtures explicitly choose light or dark,
including a separate dark home capture to inspect the connection action.

## Competitor reference map

The user confirmed Persona (`yourpersona.com`), Rene (`rene.co`), Caddy
(`caddy.app`) and Cadu (`cadu.bot`) on 26 September. Persona below refers to that
confirmed product, replacing the earlier provisional `persona.chat` reference.
There are multiple OpenMuse projects, so both relevant implementations are recorded.

| Product and primary source                                                 | Advertised capabilities relevant to Alice                                                                                               | Alice evidence / gap                                                                                                                                                                                                          |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Meta Muse](https://ai.meta.com/muse/)                                     | Persistent computer and browser, app connections, goals, reminders, background work, documents and purchases with permissions           | Browser, goals, routines, secure input and approvals exist. A Mac running Hermes is not a managed cloud VM or an independent network security boundary. End-to-end task reliability remains unproven                          |
| [Grok Bot](https://docs.x.ai/grok-bot/overview)                            | Persistent specialist bots with memory, files, computer use and background execution                                                    | Hermes profiles, agent creation, files, routines and channels exist. Each profile does not automatically receive an isolated cloud computer                                                                                   |
| [Instinct](https://instinct.com/)                                          | Text and voice contact, personal context, app/device access, calls and follow-through                                                   | Native voice and context exist. Autonomous outbound telephone calls and a hosted always-available phone service are not established                                                                                           |
| [Poke](https://poke.com/docs)                                              | Messaging channels, email, calendar, reminders, web search and integrations                                                             | Calendar/reminders and Hermes integrations exist. Each connected service and messaging channel needs its own configured credentials and delivery validation                                                                   |
| [Persona](https://yourpersona.com/) / [Band](https://yourpersona.com/band) | iMessage assistant; calls, appointments, subscriptions, forms, purchases and confirmations; optional Band advertised for preorder       | Memory, browser, calendar and approvals exist. Outbound calling and the wearable remain separate gaps. Export/deletion and privacy claims need a deployment-specific audit; no independent certification is claimed for Alice |
| [Rene](https://rene.co/)                                                   | Email/calendar coordination, browser tasks, generated artifacts, memory, health context and coordination with other people's assistants | Health, artifacts, browser and personal agent teams exist. Coordination across different people's assistants requires identity, consent and sharing protocols                                                                 |
| [Caddy](https://caddy.app/)                                                | iMessage/RCS assistant, voice memos, group chats, reminders, calendar, app integrations and proactive follow-ups                        | Similar building blocks exist through Hermes; messaging delivery, group privacy, setup simplicity and task outcomes need comparative testing                                                                                  |
| [Fo / Wajo](https://wajo.ai/)                                              | Agents working across web, mail, calendar, phone and business services; authorized bookings and purchases                               | Browser and payment approvals exist. Telephone service, service accounts and provider-dependent actions require real integrations and account setup                                                                           |
| [OpenMuse / CopilotKit](https://github.com/CopilotKit/openmuse)            | Personal agent with browser, terminal, files, visible work and rich results                                                             | Similar surfaces exist. Their availability is not evidence of equal security, isolation or task success                                                                                                                       |
| [OpenMuse / Digger](https://www.open-muse.dev/)                            | Background topic work delivered back to a main conversation, editable persistent notes                                                  | Alice has agents, channels, notes and results. Independent task sessions and predictable delivery back to the originating chat need further work                                                                              |
| [Cadu](https://cadu.bot/)                                                  | Native Hermes iPhone client with QR/link connection, chat, files, memory and activity                                                   | These surfaces exist in Alice. A side-by-side test of setup, navigation, responsiveness and recovery has not been performed                                                                                                   |

## Remaining work, ordered by user impact

1. **Independent task conversations for an existing agent.** Implemented for
   New Agent: a persisted task identity, separate profile-scoped Hermes session,
   Recents entry, and scoped recovery/retry/stop/approval routes. The canonical
   Forge chat stays intact. Local device build passed; the new regression and
   navigation suites are pending CI execution. A live test with a dedicated
   Hermes test profile remains required; no real agent was prompted for this check.
2. **Full visual and interaction review.** Review home, populated chats, Recents,
   agents, notes, agenda, settings and connection in light/dark modes, large text
   and with the keyboard. CI retains its screenshot attachments even on success.
   Add reproducible populated fixtures where current screenshots cannot cover a flow.
3. **Measured performance.** Record time to open, send and first output; scroll
   hitches, memory, reconnect delay and battery impact on long chats. The draft
   write test establishes reduced redundant storage work, not a global speedup.
4. **Remote task continuity and delivery.** Test the phone being locked, the Mac
   sleeping, a network change, reconnect and a process restart. Native iOS background
   refresh alone cannot guarantee timely delivery. A reliable hosted relay/APNs
   path needs infrastructure and credentials.
5. **External actions.** Use dedicated test accounts and explicit task authorizations
   to verify email, booking, shopping and payments. Require external confirmation
   before showing success; test retries and duplicate-action prevention.
6. **Capability gaps.** Telephone calling, hosted isolated computers, shared-user
   coordination and optional hardware need provider selection, costs, authentication
   and real integration tests. They remain gaps, not features completed by prompt text.
7. **Competitive acceptance tests.** Use the same concrete tasks, accounts, constraints
   and scoring across products: successful outcome, human interventions, elapsed time,
   cost, recovery, privacy and ease of correction. Product marketing is not a benchmark.

## Verification record

- Base GitHub run `36205543716` passed all jobs.
- Candidate run `36207313580` passed all jobs, including 1,005 unit tests and
  26 UI tests on an isolated iPhone 17 Pro simulator running iOS 26.5.
- The candidate's home, navigation, settings and largest-text chat screenshots
  were inspected. The first intended dark capture was actually light: the
  generic launch argument did not override the app theme. The fixture now sets
  Alice's own theme preference. Run `36209235081` passed all 1,031 tests; its dark
  images were inspected and exposed the prominent-button contrast defect above.
- Final application revision `05267a4`, run `36210669463`: all jobs passed,
  including 1,005 unit tests and 27 UI tests (1,032 total, no failures or skips).
  All five retained screenshots were inspected, including the corrected dark
  connection action, light home/navigation/settings and largest-text dark chat.
  The follow-up changes to this audit are documentation only.
- Local simulator/UI execution is prohibited on this Intel Mac by `AGENTS.md`.
  Device builds and compilation of test bundles are available.
- A physical-device screenshot attempt through libimobiledevice found no reachable
  device; this does not imply the CoreDevice installation connection is unavailable.
- Changes, final checks and installed revision are recorded in the associated PR.
  No real purchases, calls or messages are sent as part of this audit.

## Continuation: independent Agent Maker work

Initial application candidate `2a4dbb4`, followed by corrections on PR #34:

- Generic iPhone build and compilation of both test bundles passed with
  `xcodebuild ... -destination 'generic/platform=iOS' ... build-for-testing`.
  Candidate metadata: version 1.0, build 121, source revision `2a4dbb4`.
- The official Hermes checkout's `tests/tui_gateway/test_resume_live_lazy_session.py`
  passed all four tests with its isolated temporary homes. These check durable-ID
  and pending-title recovery, rejection of cross-profile lookup, and a missing
  session. They do not prompt a live model or use the person's Hermes state.
- New native regressions cover separate task identity, archive compatibility,
  canonical history/draft preservation, task-scoped requests, and retrying a
  first send without losing its edited text or attachments.
- Synthetic visual fixtures cover populated chats, agents, Recents, notes,
  keyboard, settings and Agenda's unconnected state in light/dark and large text.
  No real conversations are captured. Run `36262920016` passed both visual
  journeys and all eight new session tests, but failed one drawer selector and
  an older attachment test that incorrectly assumed serial upload start order.
  The selector now names the actual Recents row. The attachment check preserves
  resume-before-upload and submit-after-upload assertions; a deterministic
  reversed-completion test checks that submitted references retain user order.
- Image review found overcrowded chat hints, clipped agent rows at the largest
  text size, and Agenda's white-on-light dark-mode access button. Corrections
  hide navigation hints in populated chats and all chat hints while typing,
  allow the model control to grow, stack agent metadata at accessibility sizes,
  and explicitly contrast the Agenda action. The keyboard test also checks that
  Send is reachable above the keyboard. Final CI and image review remain pending.
- Seven isolated official Hermes persistence tests also passed. New task sessions
  opt into `follow_profile_config`; explicit model changes update held sessions
  without waking closed historical tasks. Reconnecting only auto-sends when both
  the intended chat and its complete draft remain unchanged.
- Rollback must keep the task-aware archive decoder and routing for existing
  tasks. Disable the New Agent task entry point if necessary; an older binary
  predating `agentTaskID` would mistake these conversations for canonical chats.
