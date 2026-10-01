# Alice iPhone ↔ Mac Protocol

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document defines every contract between Alice iOS and Alice's Mac/backend
components (Hermes gateway, Hermes dashboard, and the Alice Hermes plugin). It
exists so that a change on either side fails loudly and diagnostically rather
than silently behaving incorrectly.

## Architecture overview

Alice iOS talks to two independent services on the user's Mac (or server):

| Service       | Transport                  | Auth                         | Purpose                                              |
| ------------- | -------------------------- | ---------------------------- | ---------------------------------------------------- |
| Gateway       | HTTPS to `/v1/*`           | Bearer `API_SERVER_KEY`      | Chat, runs, models, tools, approvals, streaming     |
| Dashboard     | HTTPS to `/api/*`          | Username + password (Basic)  | Profiles, sessions, memory, notes, MCP, management   |
| Plugin        | Dashboard-mounted `/api/plugins/alice/*` | Dashboard session   | Pairing QR, curated memory, notes, vault cards, health |

The gateway and dashboard may run on different ports. The plugin is mounted
inside the dashboard process. Pairing delivers both sets of credentials in one
exchange. See [pairing](pairing.md) for the pairing flow.

The web companion adds a third transport: an authenticated server proxy that
forwards to the same gateway, plus a direct browser mode. Both must preserve
the same request/response semantics as the iOS client.

## Protocol version

**Current protocol version: `1`**

The pairing QR carries `v=1`. The gateway and dashboard do not currently
advertise a protocol version in their responses; Alice relies on capability
detection (see below). A future breaking change to any contract in this
document must increment the protocol version and reject incompatible clients
explicitly.

## Capability detection

Alice does not assume a fixed feature set. On connect, it probes:

1. `GET /v1/capabilities` — returns the gateway's advertised capabilities.
2. `GET /v1/models` — returns available models.
3. Dashboard manifest — returns dashboard capabilities and endpoint map.

The manifest includes a `version` string and an `advertised` list. Alice maps
these to typed `HermesCapability` values. Unknown capabilities are preserved
safely (see [HermesUnknownEvents](#unknown-events)).

**Compatibility classes:**

| Class       | Meaning                                                       |
| ----------- | ------------------------------------------------------------ |
| `current`   | Version in `HERMES_CURRENT_CONTRACT_VERSIONS` (0.21.x family) |
| `previous`  | Version matches `HERMES_PREVIOUS_STABLE` (0.20.6)            |
| `unknown`   | Anything else; capabilities are detected individually        |

Alice never sends fields the server did not advertise. Unsupported is different
from empty, offline, or unauthorized.

## Contracts

### 1. Pairing (QR → credentials)

**Request:** `alice://pair?v=1&p=<base64url(json)>`

QR payload fields:

| Field | Type   | Required | Description                                    |
| ----- | ------ | -------- | ---------------------------------------------- |
| `c`   | string | yes      | Absolute URL of the claim endpoint on dashboard |
| `t`   | string | yes      | One-time opaque bearer token                   |
| `e`   | number | yes      | Expiration epoch (seconds)                     |
| `pr`  | string | yes      | Default profile name (informational)            |

**Claim request:**

```http
POST {c}
Content-Type: application/json
Authorization: Bearer <t>

{"token":"<t>","device_name":"iPhone"}
```

**Claim response (200):**

```json
{
  "profile": "default",
  "profile_display_name": "Alice",
  "gateway": { "url": "https://...", "key": "..." },
  "dashboard": { "url": "https://...", "username": "...", "password": "..." }
}
```

| Field                 | Required | Notes                                              |
| --------------------- | -------- | -------------------------------------------------- |
| `profile`             | yes      | Canonical name of the installation's main profile  |
| `profile_display_name`| no       | Added after v1; clients that don't know it ignore it |
| `gateway.url`         | yes      | Must be http/https, same host as claim endpoint    |
| `gateway.key`         | yes      | Non-empty                                          |
| `dashboard`           | no       | `null` is valid (gateway-only connection)           |
| `dashboard.url`       | yes\*    | Same host as claim; different port allowed         |
| `dashboard.username`  | yes\*    | Non-empty                                           |
| `dashboard.password`  | yes\*    | Non-empty                                           |

\* Required when `dashboard` is not `null`.

**Error responses:**

| Status | Meaning                                    |
| ------ | ------------------------------------------ |
| 410    | Token expired or already used              |
| 401    | Token not recognized (treated as 404)       |
| 404    | Token does not exist                        |
| 403    | Network origin not allowed                  |

**Validation rules (client-side, before saving):**
- Gateway and dashboard URLs must use `http` or `https`.
- URLs must not contain embedded credentials.
- Both must belong to the same host as the claim endpoint (ports may differ).
- An HTTPS claim cannot downgrade persistent services to HTTP.
- The POST must not follow redirects.

**Current gap:** No protocol version negotiation. A future breaking change to
the claim response format could silently confuse an older client. The `v=1`
field in the QR is the only version signal; the claim response itself is
unversioned.

### 2. Chat (gateway)

**Send a message:**

```http
POST /v1/chat
Authorization: Bearer <gateway_key>
Content-Type: application/json

{
  "messages": [...],
  "stream": true,
  "profile": "default"
}
```

**Streaming response:** Server-Sent Events (SSE) or newline-delimited JSON.

Event types:

| Event                    | Direction | Description                                    |
| ------------------------ | --------- | ---------------------------------------------- |
| `delta`                  | server→client | Incremental text token                    |
| `tool`                   | server→client | Tool call start/done with status           |
| `tool_result`            | server→client | Tool execution result                     |
| `approval`               | server→client | Approval request with choices              |
| `approval_result`        | client→server | Approval response (once/session/always/deny) |
| `error`                  | server→client | Error with code and detail                |
| `done`                   | server→client | Turn complete                             |
| `subagent.start`         | server→client | Subagent activity begins (0.21+)          |
| `subagent.complete`      | server→client | Subagent activity ends (0.21+)            |
| `message.interim`        | server→client | Intermediate assistant message (optional)  |

**Message format:**

```json
{
  "role": "user|assistant",
  "content": "text or parts array"
}
```

Multimodal content uses a `parts` array with `type: "text"` and
`type: "image_url"` entries. Text-only turns may use a bare string. The
`/v1/runs` endpoint treats a top-level array as a list of messages, so
multimodal content must be wrapped in an explicit user message object.

### 3. Runs (gateway)

**Start a run:**

```http
POST /v1/runs
Authorization: Bearer <gateway_key>
Content-Type: application/json

{
  "messages": [...],
  "idempotency_key": "<uuid>",
  "profile": "default"
}
```

**Run status values:** `started`, `queued`, `running`,
`waiting_for_approval`, `stopping`, `completed`, `failed`, `cancelled`.

**Recovery:** Alice polls run status with a 180-second window that restarts on
any answered status probe. Silence ends recovery; a long run does not.

**Idempotency:** Supported when the transport advertises
`chat.run_idempotency`. The key is a deterministic UUID.

### 4. Dashboard RPC

The dashboard uses JSON-RPC 2.0 for profile-scoped operations.

**Key methods:**

| Method                | Profile-scoped | Description                                    |
| --------------------- | -------------- | ---------------------------------------------- |
| `profiles.list`       | no             | List all profiles; main has `is_default: true` |
| `session.create`      | yes            | Create a canonical session                     |
| `session.resume`      | yes            | Resume by durable ID or pending title           |
| `profiles.configure`  | yes            | Set model on a profile                         |
| `groups.*`            | yes            | Group chat operations (0.21+)                   |

**Profile scoping rule:** The home conversation always uses the main
installation profile. Agent conversations carry their own profile and canonical
session. Navigating between chats must not retarget an in-flight turn.

### 5. Plugin API (`/api/plugins/alice/`)

| Endpoint                          | Method | Auth          | Description                            |
| --------------------------------- | ------ | ------------- | -------------------------------------- |
| `pairing/session`                 | POST   | Dashboard     | Mint a pairing QR code                 |
| `pairing/claim`                   | POST   | Pairing token | Exchange token for credentials         |
| `memory`                          | GET    | Dashboard     | Read curated MEMORY.md/USER.md         |
| `memory`                          | POST   | Dashboard     | Write curated memory                   |
| `notes`                           | GET    | Dashboard     | Read agent inbox-store notes           |
| `notes`                           | POST   | Dashboard     | Add to inbox-store (append-only)       |
| `vault/cards`                     | GET    | Dashboard     | List saved payment cards               |
| `vault/cards`                     | POST   | Dashboard     | Save a payment card for a page          |
| `health`                          | GET    | Dashboard     | Mac health (disk, memory, battery)     |
| `places`                          | GET    | Dashboard     | Place trigger configuration            |

### 6. Media (`alice://file`)

A bot that saves a file writes one line, alone in its paragraph:

```
![name.ext](alice://file?path=<percent-encoded absolute path>&url=<percent-encoded web mirror>)
```

iOS parses the extension to determine type (video, audio, image, file card).
Bytes are fetched first via dashboard `api/fs/download`, then from the `url`
mirror. One download per media per session. `alice://reply` and any
`alice://` without `path` are never media.

## Ordering and timing assumptions

- **Streaming:** Events arrive in order within a turn. A `done` event
  terminates the stream. There is no guarantee of ordering across turns.
- **Approval:** An approval request may arrive at any point during a run. The
  client must be prepared to display it and collect a response. A pending
  approval survives reconnection.
- **Reconnect:** On reconnect, Alice recovers pending questions and approvals
  from the session snapshot. Recovery deduplicates by profile and session.
- **Cancellation:** Cancelling one view does not cancel work needed by another.
  When the last subscriber leaves, the transport is aborted.
- **Timeouts:** Run recovery has a 180-second window. Model reads have a
  30-second TTL. Failures are never cached.

## Unknown events

Alice preserves unknown stream events safely. A new event type from a newer
Hermes does not crash Alice; it is stored and may be displayed generically.
The contract is: **never crash on an unknown event, never silently drop it.**

## Backward compatibility rules

1. **New fields in responses are allowed** and must be ignored by older
   clients. This is the primary extension mechanism.
2. **Removing or renaming a field is a breaking change** that requires a
   protocol version increment and explicit rejection of incompatible clients.
3. **New event types are allowed** and must be preserved safely by older
   clients.
4. **New capabilities are allowed** and are gated by capability detection.
5. **A change to the pairing QR format is a breaking change** that requires
   incrementing `v`.
6. **A change to the claim response structure is a breaking change** unless it
   only adds optional fields.

## Current risks

| Risk                                                      | Severity | Mitigation                              |
| -------------------------------------------------------- | -------- | --------------------------------------- |
| Claim response is unversioned                             | Medium   | Add `protocol_version` to response      |
| No schema validation on streaming events (iOS side)       | Medium   | Add Codable validation with unknown-key preservation |
| Dashboard RPC methods are not versioned                   | Low      | Capability detection is sufficient      |
| No contract test for the claim response format            | Medium   | Add fixture test for claim response     |
| `alice://file` path is not validated for traversal        | Low      | Already percent-encoded; iOS resolves locally |
| No explicit rejection of incompatible protocol versions   | Medium   | Gate on `v` in QR and `protocol_version` in responses |

## Contract tests

The following tests should exist to protect these contracts:

1. **Pairing claim response parsing** — verify all required fields are present
   and validated. Fixture in `src/lib/hermes-contract-fixtures.ts`.
2. **Streaming event round-trip** — verify known and unknown event types are
   handled. Covered by `src/lib/chat-stream.test.ts`.
3. **Capability detection** — verify version classification and capability
   gating. Covered by `src/lib/gateway.test.ts`.
4. **Profile scoping** — verify home and bot profiles are never confused.
   Covered by iOS `HomeChatSession` and `BotChatSession` tests.
5. **Media line parsing** — verify `alice://file` parsing. Covered by
   `mcp-servers/cobalt-mcp/lib.test.mjs`.
