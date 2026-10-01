# Alice — Debugging Guide

How to find out what is wrong, surface by surface. Prefer the built-in
diagnostics before touching code. **UNKNOWN** marks missing evidence.

## Golden rules

1. Reproduce before fixing: "for a bug, confirm it reproduces and that the
   fix removes it" (`AGENTS.md` task checklist).
2. Never diagnose against a person's real Hermes: do not send prompts,
   change settings or restart it as part of routine tests (`AGENTS.md`).
3. A clean build is not evidence a feature works against Hermes
   (`AGENTS.md` first paragraph).
4. "If a check fails, diagnose it; do not weaken the check or update
   snapshots merely to turn it green" (`AGENTS.md`).

## First stop: the phone's own diagnostics

Settings › Advanced › Developer mode → Settings › Developer:

- **Checks** (`ios/Alice/Features/Developer/DiagnosticChecks.swift`):
  Hermes reachability and latency, the Alice plugin's presence, one time
  zone per agent, calendar, notifications and Bark, proactive routines,
  storage size (three largest settings when over 256 KB), freezes in the
  last 10 minutes (`HitchMonitor`), and Hermes messages Alice does not
  understand yet — each failed check points at its own subsystem
  (`docs/verification.md`).
- **Performance meter**: FPS, late frames and freezes; debug builds log
  freezes with the main-thread functions (`stall.in` / `stall.at`).
- **Tools**: component gallery (every rich block against a sandbox store
  with no Hermes behind it), share a report, send diagnostics to the Mac
  (`docs/verification.md`).

The uploaded dump is readable on the Mac through the plugin's
`alice_app_status` and `alice_recent_errors` tools
(`hermes-plugin/plugin.yaml`).

## Symptom → diagnosis table

### "Cannot connect / pairing fails"

| Symptom | Likely cause | Where to look |
| --- | --- | --- |
| QR scan shows expired/used (HTTP 410/401/404) | Token TTL passed or already claimed; dashboard restart invalidates outstanding QRs (in-memory store) | `docs/pairing.md` §4; `hermes-plugin/dashboard/plugin_api.py` pairing routes |
| Claim rejected 403 | Network origin not allowed: claim accepts loopback and Tailscale IPv4 `100.64.0.0/10`, reading the peer address; forwarded headers reject the request outright | `docs/pairing.md` §4 |
| Gateway not reachable after pairing | Gateway provisioning: `API_SERVER_HOST=127.0.0.1` + `tailscale serve` forward must exist; a QR is only emitted after an authenticated probe succeeds | `docs/pairing.md` §3 |
| Partial connection (gateway ok, dashboard fails) | Valid state: `dashboard: null` is legal; retry only the dashboard, never re-claim the QR | `docs/pairing.md` §2 |
| Phone on LTE, Mac on tailnet only | Phone must reach the Mac on the same network or through Tailscale | [README.md](../README.md); `ios/project.yml` ATS exceptions |

### "No reply / stream stops"

- Check Hermes itself is running (the morning briefing's Mac health covers
  "whether Hermes is running"; `health.py`).
- Home chat: run recovery has a 180 s budget that restarts whenever a
  status probe is answered — "silence ends recovery, a run that is merely
  long does not" (`HermesChatStream.swift` `RunRecoveryBudget`).
- Bot chat: the turn needs the saved dashboard connection; "if it remains
  unavailable, the turn fails visibly" (former `docs/architecture.md`,
  now ARCHITECTURE.md §6).
- Distinguish states: "Unsupported is different from empty, offline or
  unauthorized" (`AGENTS.md` Hermes contract). Check `HermesErrors.swift`
  and the models error surfaces (`modelsError`, `modelListIsPartial` in
  `AppStore.swift`).
- Missed interim/stream events: the server only emits `message.interim`
  when `display.interim_assistant_messages` is true in Hermes' config —
  the user's `~/.hermes/config.yaml` had it false
  (`docs/plan-2026-09-20-backlog.md` bug 15 note).
- Events missed while suspended are recovered by `EventResume.swift` and
  quiet-turn checks (`RoutineQuietRuns.swift`).

### "The agent did something wrong / repeated a payment"

- Errand purchase: the pay gate (`errands.py`) refuses card fills and
  paying clicks until the person approves the exact checkout (ten-minute
  window). If a payment outcome is unknown, the ledger refuses a second
  payment on the same shop until the first outcome is known
  (`errands.py`, `docs/purchases.md` steps 10–12).
- If the purchase stopped after approval, "do not claim there was no
  charge: check the order first" (`docs/purchases.md` step 12).
- Chat actions that add to a cart are refused in chat (`is_cart_action`,
  `purchase_flow.py`); a purchase needs a chosen option.

### "Card fill does nothing on the bank page"

Known limitation: "Hermes finds card fields by English names and
autocomplete tokens; if a Spanish bank page has neither, the fill finds
nothing and Alice asks the person to type the card in the live view"
(`docs/HANDOFF.md` open problem 1). The vault card is bound to the origin
it was saved for (`vault_cards.py`).

### "Live browser is choppy"

Expected: JPEG frames over long-polling, not video (`browser_live.py`,
`docs/HANDOFF.md` open problem 2). Check the Mac's load reading
(`health.py`) and that the shared Chromium (headless,
`<hermes home>/chrome-debug`, CDP on loopback) is running.

### "Notifications did not arrive"

- iOS background execution is opportunistic; there is no always-on channel
  and no APNs (`AGENTS.md`, `docs/proactive.md`).
- The Mac notifier needs Bark configured (key in login Keychain,
  `alice-bark`) and reads the Hermes DBs read-only — check its state file
  at `~/Library/Application Support/AliceNotifier/state.json`
  (`alice_notifier.py`).
- Developer Checks validates notifications and Bark end-to-end
  (`DiagnosticChecks.swift`).

### "Archive / data looks wrong"

- Old conversations: the archive migrates a legacy single-array blob to
  per-conversation keys on launch (`ConversationArchive.swift`).
- Unreadable archives are retained for recovery and must never be replaced
  with an empty one (`AGENTS.md` Data contract).
- New Codable fields need explicit backward-compatible decoding — a Swift
  default does not make synthesized decoding compatible (same contract).

### "Model picker empty or wrong provider billed"

- `modelsError` explains why the list is empty; `modelListIsPartial` is
  true when only `/v1/models` answered (`AppStore.swift`).
- Provider routing: picking a model under a provider records
  `selectedProvider`; without it the same model id can be routed to the
  wrong provider "which billed for it and refused"
  (`AppStore.swift` comments). Clearing an agent's fallback writes an
  empty list so a leftover chain is not billed (ARCHITECTURE.md §6).

### "Web: cannot reach Hermes"

- Proxy mode: check `HERMES_COOKIE_SECRET` and the sealed `hermes_gate`
  row; the server refuses private hostnames in public contexts
  (`gateway.server.ts`, `outbound-http.server.ts`).
- Direct mode: the browser must hold the key by design — if it cannot
  fetch it, check the authenticated `device-secret` API
  (`hermes-direct.ts`, `SECURITY.md`).
- Local machine access requires the configured verified owner
  (`owner.server.ts`).

### "Hermes updated and something broke"

1. Read the release notes and compare changed source contracts at a tag.
2. Update fixtures with their exact source commits; keep older regression
   cases.
3. Run the read-only live contract check against a dedicated test
   installation: `npm run test:hermes:live` with `HERMES_LIVE_URL` and
   `HERMES_LIVE_KEY` from the environment (`docs/verification.md`).
4. Remember the plugin is loaded once per Hermes process — restart the
   gateway and the dashboard after any plugin change
   ([README.md](../README.md) step 1).

## Tool-specific tips

- **iOS logs:** OSLog in `HermesClient.swift`; the diagnostics log
  (`DiagnosticsLog.swift`) with `stall.in`/`stall.at` for freezes.
- **Web logs:** `alice_operational` / `alice_alert` records; API handlers
  expose Alice's own overhead via the `Server-Timing` header
  (`docs/operational-telemetry.md`).
- **Plugin logs:** logger name `hermes_dashboard_plugin_alice`
  (`dashboard/plugin_api.py`); secrets are never logged
  (`docs/pairing.md` §4).
- **Tests as oracles:** the plugin's 40 test files document intended
  behavior per module (`hermes-plugin/tests/`); iOS unit tests cover the
  contracts (`ios/AliceTests/`, 137 files); web unit tests document
  transports and sync (`src/lib/*.test.ts`).

## When evidence is missing

If a behavior cannot be reproduced locally (for example: real purchases,
push delivery while suspended, live model conversation quality), say so —
"not checkable here" is an acceptable answer and expected in reports
(`AGENTS.md` Alice specifics).
