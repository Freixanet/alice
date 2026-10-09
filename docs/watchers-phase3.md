# Phase 3: watch notices and one morning briefing

Settings → Watches now has a morning briefing, enabled by default at **08:00 Europe/Madrid**. Select a time and save it. It includes only open `needs_review`/`blocked` Review Tasks and watcher notifications caught since the previous briefing. Empty means no message and no model invocation. Saving an already elapsed time waits until tomorrow; a briefing already queued today is not sent again after changing the time. Madrid daylight saving time is respected.

Each watch delivery is one marked chat card: what happened, why it matters and one suggested next step. Its button sends that text as a normal chat reply. It does not approve a Task or execute an external action. Source text is untrusted; the notice-writing turn has no offered tools and a tool guard. Unexpected model formatting uses a safe review reply without another model call.

Notifications for the same owner share the existing 60-second batch, even across watches. Delivery keeps the immutable Hermes receipt ID. Removing one watch preserves other watches' pending items. The notification limit is now six batches per owner per ten minutes, which also prevents rotating watches from bypassing the limit.

The briefing reuses the existing **no-agent** minute poller; no additional routine types were added. Installation pauses and preserves only Alice's known older `Buenos días` / `alice_buenos_dias.py` template to avoid a second morning briefing. Other existing routines are unchanged. The new briefing needs Hermes running and uses the existing Bot Chat delivery and optional Mac/Bark notifications.

## Daily counter

Settings → Watches shows separate proactive and briefing counts for today and the last seven days, in the configured briefing timezone. It records Hermes model invocations before dispatch, including failed attempts and retries; queuing, empty polls and empty briefings count zero. Nested transport helpers do not double-count the same invocation. Ordinary chat replies and cheap classification are outside this counter. It is not an estimate of remaining Plus quota, tokens or billing; provider-internal HTTP retries are not independently observable here. Accounting uses the inspected Hermes `agent.chat_completion_helpers` functions and is not a claim of universal Hermes compatibility.

## Verification before installation

- Tests were written first and observed failing before implementation.
- Full plugin run: 687 tests, 683 passed, one skipped and three blocked by Codex's outer sandbox (`sandbox_apply: Operation not permitted`). The four isolated Seatbelt tests all passed outside that sandbox. After the final migration guard, 55 focused tests passed, including the purchase-off gates.
- Eight standalone Swift parser checks passed. Five native XCTest cases were added for cards, duplicate suppression and archive compatibility; simulator unit/UI tests were not run because this Mac requires permission to start a simulator. A physical-device build is the native compilation check.
- No fixture test sends a real email, calls a model, changes the user's settings or tests payments. Purchases remain disabled and their tools unregistered.

## Three checks on the iPhone

1. **One batch, one marked card.** In chat ask: “Crea una vigilancia de los emails cuyo asunto contenga ALICE-PHASE3-TEST. Avísame de cada email nuevo; no ejecutes acciones sobre ellos.” Wait for Alice to confirm a configured, active filter. Note today's watch-message counter. Send two emails to your connected Gmail account with subject `ALICE-PHASE3-TEST`, less than 45 seconds apart, and bodies “Primera actualización de prueba” and “Segunda actualización de prueba”. Allow the email polling interval plus up to two minutes for batching. In Alice's chat you should see one marked notice mentioning both updates, why they matter and one reply button; normally the watch-message counter increases by one (retries can increase it further).
2. **One tap replies.** Tap the notice's suggestion. You should see one normal outgoing chat reply and Alice's answer. The button must not send an email, approve a Task or make a payment. The ordinary response is outside the proactive counter.
3. **One morning briefing.** Ask Alice to create a blocked test Task titled “Prueba del resumen” with the question “¿La cierro?”. In Settings → Watches, select a time two minutes ahead in **Europe/Madrid** and save it (if today's briefing already ran, test tomorrow). Within a minute after that time, one marked morning card should mention the blocked Task and caught updates. The briefing counter normally increases by one. Restore 08:00, close the test Task and delete the test watch when finished. On a subsequent day with no open review/blocked Tasks or new watch notifications, nothing should arrive and the counter must not increase.

## Recovery

Disable the morning toggle to stop this briefing; watches continue. The installer saves the previous plugin under `~/.hermes/backups` and records its source commit in `INSTALLED_FROM`. Legacy morning jobs remain paused, not deleted. Keep the watcher journal and its morning cursor/call ledger when rolling back; never erase app data to reinstall.
