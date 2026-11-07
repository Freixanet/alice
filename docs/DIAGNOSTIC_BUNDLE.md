# Diagnostic bundle

A structured set of files that can be provided to a coding agent when
reporting a bug, without exposing secrets.

**Audited at:** `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 October 2026)

## How to collect a diagnostic bundle

### From the iPhone

```bash
# Copy the app's data container off the phone
xcrun devicectl device info apps --device <DEVICE_ID>
# The diagnostics log is in Documents/diagnostics.log
# The conversation files are in Application Support/Conversations/
```

Or use the in-app `/debug` command, which posts a summary to Hermes.

### From the Mac (Hermes)

```bash
# Hermes gateway logs
tail -n 200 ~/.hermes/logs/gateway.log

# Hermes dashboard logs
tail -n 200 ~/.hermes/logs/dashboard.log

# Alice plugin state
ls -la ~/.hermes/plugins/alice/
cat ~/.hermes/plugins/alice/plugin.yaml

# Memory keeper state (per profile)
ls -la ~/.hermes/profiles/<profile>/.alice/memory/
cat ~/.hermes/profiles/<profile>/.alice/memory/changes.json
cat ~/.hermes/profiles/<profile>/.alice/memory/settings.json
```

## What the bundle contains

### 1. App diagnostics snapshot

From `AppDiagnostics.swift` — the same data that `/debug` sends to Hermes:

- **Device ID** — vendor identifier (pseudonymous)
- **Version and build** — e.g. `1.0 (121)`
- **Git revision** — the commit the app was built from
- **Hermes wellbeing** — connected, dashboard ready, gateway configured
- **Unknown events** — Hermes stream events Alice does not recognize
- **Recent diagnostics log lines** — the last 200 lines (IDs, states, errors)

**Never includes:** message content, API keys, Hermes addresses, user
email, session tokens.

### 2. Diagnostics log

From `Documents/diagnostics.log` (and `.old.log` rollover):

- Timestamped trace of reply travel, connection state changes, feed sync,
  persistence events, stall traces (debug builds only).
- Capped at 1.5 MB. Contains IDs and states, never message text.

### 3. Diagnostic checks output

From `DiagnosticChecks.swift` — the Developer screen's check results:

- Hermes reachability and latency
- Alice plugin presence
- Time zone consistency
- Calendar access
- Notification permissions
- Bark relay configuration
- Proactive routines
- Storage size (with the three largest settings when over 256 KB)
- Main-thread freezes in the last 10 minutes
- Unknown Hermes events

### 4. Hermes contract version

From `src/lib/hermes-contract-fixtures.ts`:

- The Hermes version the app was tested against (e.g. `0.21.3`)
- The source commit of the Hermes checkout (`b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`)

### 5. Conversation archive state (non-content)

Without opening any conversation, the structure of the archive:

- Number of conversations
- Whether the archive is in split or blob form
- Whether there are skipped (unreadable) conversations
- Whether the salvage key has content
- Whether the migration marker exists
- Storage size breakdown

### 6. Plugin state (non-content)

- `settings.json` — whether cleanup is set to apply, whether learning is on
- `changes.json` — the last N changes (with removed text — this is the
  person's data, so it should be redacted or provided only to a trusted
  agent)
- `entries.json` — entry counts and sources (agent, person, hand, legacy)
- No `.env` files — never include secrets

### 7. Web operational state (if relevant)

- Vercel deployment URL (the immutable one, not the production alias)
- `X-Alice-Version` header value
- `alice_operational` and `alice_alert` log entries (no user content)
- Server-Timing header values

## What the bundle does NOT contain

- **Message content** — never. Not from the phone, not from Hermes, not
  from the web.
- **API keys, tokens, passwords** — the Hermes key, dashboard password,
  OAuth tokens and API keys are never included.
- **Hermes address** — the gateway and dashboard URLs are sensitive. The
  diagnostics snapshot includes `gateway_configured: true/false`, not the
  address itself.
- **User email or account ID** — the diagnostics snapshot uses a vendor
  device ID.
- **Attachment data** — photos and files attached to messages are never
  included.
- **Memory content** — the text of memory entries is the person's data.
  Only metadata (counts, sources, timestamps) is safe to share.

## How to use the bundle with a coding agent

1. Collect the bundle using the instructions above.
2. Redact anything that might contain personal data (the `changes.json`
   file contains removed memory entries — provide only to a trusted agent
   or redact the text).
3. Provide the bundle alongside:
   - A description of what happened (what the person was doing, what they
     expected, what they saw instead).
   - The exact version and build (from the diagnostics snapshot).
   - The Hermes version (from the contract fixtures).
   - Whether the issue is reproducible.
4. The coding agent should read:
   - `START_HERE.md` (if it exists) or `AGENTS.md` for engineering rules.
   - `docs/architecture.md` for system structure.
   - `docs/verification.md` for how to check a fix.
   - The diagnostic bundle for the specific failure.
