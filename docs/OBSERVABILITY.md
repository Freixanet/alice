# Observability

How Alice's diagnostics are structured so that when something fails, a human
or AI agent can understand what failed and where without reproducing
everything manually.

**Audited at:** `2420a2f89a229ceb334d06e933e1c7a1881f9271` (main, 1 October 2026)

## Design principles

Alice is a personal project, not an enterprise system. It does not use
Datadog, Sentry, OpenTelemetry or any external observability platform. The
goal is: when Alice fails, the diagnostic information to understand the
failure is already on the phone or the Mac, and can be copied to an engineer
or coding agent.

### What a useful event answers

Every diagnostic event should answer as many of these as are safe:

1. **WHAT happened** — a stable, machine-readable category (e.g.
   `chat.stream.disconnected`, `feed.sync.failed`).
2. **WHEN** — ISO 8601 timestamp with the device's timezone.
3. **WHICH subsystem** — the component that produced the event (chat, feed,
   pairing, Hermes RPC, persistence, agent execution, background work).
4. **WHICH operation/session identifier** — a conversation ID, a run ID, a
   bot name, a routine name — but never a message's content.
5. **RESULT** — success, failure, timeout, retry, cancelled.
6. **WHY** — the error category, if known (network, auth, timeout, decode,
   schema). Never the raw error text if it might contain user data.

### Privacy and security

- **Never log credentials.** The Hermes key, dashboard password, API tokens
  and OAuth secrets are never written to any log.
- **Never log message content.** The diagnostics log carries IDs, states and
  timings, never the text of a conversation.
- **Minimize personal data.** Bot names and conversation IDs are
  pseudonymous enough for debugging. Real names, email addresses and phone
  numbers are not logged.
- **Bound log growth.** The iOS diagnostics log is capped at 1.5 MB with
  one rollover. Vercel runtime logs are retained for no more than 30 days.
- **Sensitive logging is opt-in.** The developer screen's diagnostics
  upload is an explicit action, not automatic.
- **Debug and production differ.** Debug builds write stall traces to the
  diagnostics log. Production builds do not.

## Current diagnostic surfaces

### iOS diagnostics log (`DiagnosticsLog.swift`)

A plain-text trace in the app's Documents directory, copied off the phone
with `devicectl --domain-type appDataContainer`.

- **Location:** `Documents/diagnostics.log` (with `.old.log` rollover)
- **Cap:** 1,500,000 bytes (1.5 MB). When exceeded, the current file
  becomes `.old.log` and a new file starts.
- **Content:** IDs, states, errors and timings. Never message text.
- **Format:** `<ISO8601 timestamp> <message>`
- **Access:** `DiagnosticsLog.recentLines(limit:)` returns the last N lines.
  Developer screen shows them. `/debug` chat command includes them in a
  summary. `POST api/plugins/alice/app/diagnostics` uploads them to Hermes.

### iOS structured logging (`os.Logger`)

Several subsystems use `os.Logger`:

| Subsystem | Category | Purpose |
| --------- | -------- | ------- |
| `alice` | `feed` | Feed sync, cache, outbox |
| `alice` | `launch-cache` | Launch cache read/write |
| `alice` | `retired-preferences` | Preference eviction |
| `alice` | `diagnostics` | Diagnostic log itself |

### iOS diagnostic checks (`DiagnosticChecks.swift`)

The Developer screen runs a set of checks:

- Hermes reachability and latency
- Alice plugin presence
- Time zone consistency across agents
- Calendar access
- Notification permissions
- Bark relay configuration
- Proactive routines
- Storage size (with the three largest settings when over 256 KB)
- Main-thread freezes in the last 10 minutes (`HitchMonitor`)
- Unknown Hermes events

### iOS stall monitoring (`HitchMonitor.swift`)

A debug build writes each main-thread freeze to the diagnostics log with
the functions the main thread was in (`stall.in`, `stall.at`). A stall of
many seconds whose stack is the resume path is the app having been
suspended, not a hitch while it was on screen.

### iOS app diagnostics (`AppDiagnostics.swift`)

A snapshot sent to Hermes via `POST api/plugins/alice/app/diagnostics`:

- Device ID (vendor)
- Build version and revision
- Hermes wellbeing (connected, dashboard ready, gateway configured)
- Unknown events
- Recent diagnostics log lines

### Mac/backend diagnostics

The Hermes gateway and dashboard write logs to `~/.hermes/logs/`. The
Alice plugin writes to its own state files in
`~/.hermes/profiles/<profile>/.alice/memory/`. The Mac notifier
(`mac/notifier/`) is an optional Python service that forwards Hermes
activity as local macOS notifications.

To collect Mac diagnostics:

```bash
# Gateway and dashboard logs
tail -n 200 ~/.hermes/logs/gateway.log
tail -n 200 ~/.hermes/logs/dashboard.log

# Plugin state (non-content)
cat ~/.hermes/profiles/<profile>/.alice/memory/settings.json
ls -la ~/.hermes/plugins/alice/

# Notifier status
python -m unittest discover -s mac/notifier
```

The Mac logs do not include message content, API keys or Hermes
addresses. They contain request categories, response codes and
timings.

### Web operational telemetry (`operational-telemetry.md`)

Two machine-readable record types in Vercel runtime logs:

- `alice_operational` — bounded anonymous measurements (latency, vitals)
- `alice_alert` — stable alert codes with `warning` or `critical` severity

Fields that are never accepted: content, prompts, responses, filenames,
raw paths, query strings, Hermes URLs, keys, complete user-agent strings,
email addresses, user ids, session ids, arbitrary error text.

### Release identity

Every API response includes `X-Alice-Version` and `X-Alice-Environment`.
`GET /api/status` returns the same closed release identity with
`Cache-Control: no-store`. It contains no deployment URL, account
identifier or secret.

## Coverage by subsystem

| Subsystem | What is logged | Where | Gaps |
| --------- | -------------- | ----- | ---- |
| iOS lifecycle | App launch, backgrounding, foregrounding | DiagnosticsLog | Launch time not logged in production |
| Networking | Connection state, model list, gateway errors | DiagnosticsLog, os.Logger | No structured error categories |
| Pairing | QR scan, connection save, connection failure | DiagnosticsLog | Pairing failure reason not always specific |
| Streaming | Stream start, stream end, stream disconnect | DiagnosticsLog | No per-token timing |
| Mac/backend connectivity | Reachability check, latency | DiagnosticChecks | No connection history |
| Hermes | Wellbeing, unknown events, manifest | AppDiagnostics, DiagnosticChecks | No RPC call tracing |
| Mac backend | Gateway/dashboard logs, plugin state | `~/.hermes/logs/` | No structured log aggregation |
| Mac notifier | Delivery, relay health | `~/.hermes/logs/` | No delivery success/failure rate |
| Agent execution | Run start, run end, approval, cancellation | DiagnosticsLog | No agent decision tracing |
| Background work | Background refresh, notification delivery | DiagnosticsLog | No delivery success/failure rate |
| Scheduled work | Routine run start/end, quiet runs | DiagnosticsLog | No schedule drift detection |
| Persistence | Save failures, migration, salvage | DiagnosticsLog, FileConversationStorage.takeFailure | No data integrity monitoring |
| Protocol errors | Unknown events, decode failures | AppDiagnostics, HermesUnknownEvents | No protocol version logging |
| External services | Feed source failures | FeedStore (os.Logger) | No external service health dashboard |

## Recommended structured diagnostic principles

### 1. Stable event categories

Every log line should begin with a stable, dotted category:

```
chat.stream.connected gateway=...
chat.stream.disconnected reason=websocket_closed conversation=...
chat.reply.failed conversation=... error=timeout
feed.sync.failed reason=offline posts_cached=12
pairing.completed profile=... dashboard=...
persist.conversation.saved id=... bytes=...
persist.conversation.failed id=... error=write_failed
persist.migration.completed from=blob to=split records=...
```

### 2. IDs, not content

Every event that refers to a conversation, message, agent or routine uses
its ID, not its content. The diagnostics log already follows this rule.

### 3. Error categories, not raw text

Network errors should be categorized (`network.timeout`,
`network.unreachable`, `auth.unauthorized`, `decode.failure`) rather than
passing through the raw `Error` description. The raw description may
contain user data.

### 4. Bounded and rotatable

The diagnostics log is already bounded at 1.5 MB. The web alert system
cools down repeated alerts for one minute per code, route and metric.

### 5. Diagnostic bundle (see DIAGNOSTIC_BUNDLE.md)

A structured set of files that can be provided to a coding agent when
reporting a bug, without exposing secrets. See
[DIAGNOSTIC_BUNDLE.md](DIAGNOSTIC_BUNDLE.md).

## What not to add

- **No external observability platform.** Alice is a personal project.
  Datadog, Sentry and similar services add cost, privacy risk and a
  dependency. The existing first-party diagnostics are sufficient.
- **No remote telemetry.** The phone never sends logs to a server unless
  the person explicitly uploads them through the Developer screen.
- **No verbose logging in production.** Debug builds write stall traces;
  production builds do not.
- **No message content in logs.** This is a hard rule, not a preference.
