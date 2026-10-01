# Debugging

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

## Diagnostic tools

### iOS Developer mode

Enable: Settings → Advanced → Developer mode. Then Settings → Developer:

- **Checks** (`DiagnosticChecks.swift`): Hermes reachability and latency,
  Alice plugin presence, time zone consistency across agents, calendar
  access, notifications, proactive routines, storage size (with three
  largest settings when over 256 KB), freezes in last 10 minutes
  (`HitchMonitor`), and Hermes messages Alice does not understand yet.
- **Performance meter**: FPS, late frames, freezes beside the home
  indicator. Debug builds write each freeze to the diagnostics log with
  the functions the main thread was in (`stall.in`, `stall.at`).
  A stall of many seconds whose stack is the resume path is the app
  having been suspended, not a hitch while it was on screen.
- **Tools**: component gallery, share report, send diagnostics to Hermes,
  test notification, resets.
- **Recent activity** from `DiagnosticsLog` — ids, states, timings, never
  message text. Shows the build.

### DiagnosticsLog

`DiagnosticsLog` records activity ids, states and timings — never message
text. Check this first when investigating iOS behavior issues.

### Unknown Hermes events

`HermesUnknownEvents` preserves events Alice does not yet understand. Check
Developer → Checks → "Hermes messages Alice does not understand yet" to see
if a new Hermes version is sending events Alice doesn't handle.

## Common diagnostic procedures

### Cannot connect to Hermes

1. Check Settings → Developer → Checks → Hermes reachability.
2. Verify gateway URL and key are correct (Settings → Configuration).
3. Check network: is the iPhone on the same network or Tailscale?
4. Check ATS: public addresses require HTTPS. Tailscale `.ts.net` and
   `100.64.0.0/10` have HTTP exceptions.
5. Check if Hermes gateway is running: `launchctl print gui/$(id -u)/ai.hermes.gateway`.
6. Check if the gateway port is correct. A freshly provisioned main-profile
   gateway uses ports 8643–8669.
7. If pairing just happened: verify the gateway was provisioned (the plugin
   probes `/v1/capabilities` and `/v1/models` before issuing the QR).

### Chat not receiving responses

1. Check if the WebSocket is connected (Developer → Checks → Hermes
   reachability).
2. Check for unknown events (Developer → Checks).
3. Check `HermesChatStream` parsing — is the event type recognized?
4. Check if the session was created/resumed correctly
   (`HomeChatSession`/`BotChatSession`).
5. Check `EventResume` — is the seq tracking working?
6. Check if the profile/session identity is correct. Navigating between
   chats must not retarget an in-flight turn.

### Conversation data lost or corrupted

1. Check `ConversationArchive.load()` — does it return `.unreadable`?
2. If unreadable, the bytes are retained for recovery. Do NOT replace with
   an empty archive.
3. Check if the old blob format is being read (backward compatibility).
4. Check `Codable` decoding — a Swift property default does NOT make
   synthesized decoding backward-compatible. Old archives must be read
   before extending models.
5. Check if the per-chat key is correct (`alice.conversation.<id>`).

### App freeze or hitch

1. Enable Developer → Performance meter.
2. Check FPS, late frames, freezes.
3. Look at the diagnostics log for `stall.in` and `stall.at` entries.
4. A stall of many seconds whose stack is the resume path = app suspended,
   not a hitch.
5. Check if `AppStore` is doing work on the main actor that should be
   off-thread (e.g., `ConversationArchive` encoding).

### Pairing fails

1. Check if the Alice plugin is enabled in Hermes.
2. Check if the dashboard was restarted after plugin installation.
3. Check if the QR code has expired (TTL 5 minutes). Open the Alice tab
   again for a new QR.
4. Check if the iPhone can reach the Hermes address (same network or
   Tailscale).
5. Check if the gateway was provisioned (the plugin probes before issuing
   the QR — if the probe fails, no QR is shown).
6. Check if the claim is from a loopback or Tailscale address. LAN
   addresses that aren't Tailscale are rejected.
7. Check if `X-Forwarded-For` or `Forwarded` headers are present — their
   presence rejects the claim outright (anti-spoofing).

### Web companion issues

1. Check `X-Alice-Version` and `X-Alice-Environment` headers.
2. `GET /api/status` — is the endpoint healthy?
3. Check browser console for CSP violations.
4. Check if the Hermes connection cookie is present (httpOnly).
5. Check if PGLite initialized correctly (dev) or DATABASE_URL is set
   (prod).
6. Check rate limiting — `alice_rate_limit` table.
7. Check if the owner is verified (`ALICE_OWNER_EMAIL`).

### Plugin issues

1. Check if the plugin is enabled: `hermes plugins list`.
2. Check if the plugin is at the right path: `~/.hermes/plugins/alice/`.
3. Check if Hermes was restarted after plugin update (loads once per
   process).
4. Run plugin tests: `~/.hermes/hermes-agent/venv/bin/python -m unittest
   discover -s hermes-plugin/tests`.
5. Check if the Hermes version is compatible (0.21.x).
6. Check if `pypdf` is vendored (`hermes-plugin/vendor/`).
7. Check if the dashboard tab bundle exists
   (`hermes-plugin/dashboard/dist/index.js`).

### Egress guard blocking a command

1. The agent read outside content (web page, email) — session is tainted.
2. The command matches an egress pattern (curl POST, scp, ssh, etc.) or
   a secrets pattern (~/.ssh, .env, vault).
3. The approval card should show the exact command.
4. If the command is safe, the user can approve it.
5. To debug the regex: check `egress_guard.py` — `READS_OUTSIDE`,
   `RUNS_CODE`, `_EGRESS`, `_SECRETS` patterns.

### Live browser not working

1. Check if Chromium is running on the Mac.
2. Check if `browser_live.py` can connect to the browser (CDP).
3. Never test in the shared agent browser (127.0.0.1:9222). Use a
   temporary Chrome on another port.
4. Check if the browser outlived a dashboard/gateway restart.

## Log locations

| Component | Log location | Notes |
|-----------|-------------|-------|
| iOS app | DiagnosticsLog (in-app) | Never message text |
| Hermes gateway | `~/.hermes/` logs | Process logs |
| Hermes dashboard | `~/.hermes/` logs | Process logs |
| Plugin | Dashboard logs | _log = `hermes_dashboard_plugin_alice` |
| Web (Vercel) | Vercel dashboard | `alice_operational`, `alice_alert` |
| Mac notifier | launchd logs | |

## When to check Git history

- A behavior changed and you don't know why — check `git log` for the
  relevant file.
- A test exists and you don't know what it's guarding — check the commit
  that added it.
- A workaround looks odd — check the commit message for context.
- A regression appeared — check if a recent commit changed the relevant
  code path.

## When to check Hermes source

- A Hermes API contract changed — check the official Hermes source at the
  relevant tag/commit.
- An unknown event type appeared — check Hermes' event definitions.
- A management endpoint changed — check Hermes' gateway/dashboard source.
- The plugin tests use a pinned Hermes commit
  (`b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`) in CI.

Contract fixtures are in `src/lib/hermes-contract-fixtures.ts`. Source
tags and commits are stored there. ([docs/hermes-contracts.md](hermes-contracts.md))
