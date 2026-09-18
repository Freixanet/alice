# Architecture

## Product surfaces

| Surface         | Responsibility                                                     | Entry points                                                       |
| --------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| iOS — primary   | Native conversations, agent work and configuration                 | `ios/Alice/AliceApp.swift`, `Features/`, `Networking/`, `Storage/` |
| Hermes plugin   | Pairing QR, curated memory and compatible notes stores             | `hermes-plugin/dashboard/plugin_api.py`                            |
| Web — companion | Browser access, account boundaries and encrypted conversation sync | `src/routes/`, `src/components/`, `src/lib/`                       |
| Mac notifier    | Optional local notifications from Hermes activity                  | `mac/notifier/`                                                    |

## Connection and identity

The native app connects directly to services on the user's Hermes host. The
gateway provides the agent API; the dashboard provides management and canonical
profile/session operations. They may have different ports and credentials.
Pairing exchanges a short-lived code for these connections. See
[the protocol](pairing.md) and [user instructions](getting-connected.md).

The home conversation belongs to the default installation profile. An agent
conversation retains its explicit profile and canonical session; navigating to
another chat must not retarget an in-flight turn. `HomeChatSession`,
`BotChatSession`, `HermesRPC` and `GatewayServerRequests` hold these contracts.

An `@agent` reply retains its own profile and session on the message. Pending
questions and approvals are recovered from that session, even when there is no
separate agent chat, and belong to the chat that sent the mention. Recovery
deduplicates by profile and session without changing the home chat's identity.
Agent mentions and team turns always use the agent's canonical dashboard session,
including during reconnect. Sending probes the saved dashboard connection when
needed; if it remains unavailable, the turn fails visibly. The main-profile
gateway cannot impersonate an agent or substitute for its tools and instructions.

The web supports an authenticated server proxy and a direct browser transport.
Keep operation semantics and profile scoping equivalent. Local machine access
belongs only to the configured, verified owner. See [security](../SECURITY.md).

## Storage and lifecycle

iOS stores connection secrets in Keychain and conversation archives/preferences
in UserDefaults. Each conversation is stored under its own key after the first
save; an older single-array blob is still read on launch and rewritten in the
split form. Codable migrations must preserve older archives. Unreadable bytes
are retained for recovery rather than overwritten with an empty archive. User
edits are persisted immediately; backgrounding saves current conversation
state. Gateway address policy lives in `HermesAddress`. A future move to a
database must include migration and recovery tests.

The web persists state per account. Persisted updates must remain immutable:
transient input changes skip serialization when persisted field references are
unchanged, with the cache separated by account. Optional encrypted sync uses device keys,
conversation replicas and a server-side immutable verifier. A pull cursor is
saved with the corresponding state. Disconnection, retries and key mismatch are
different states, not a single on/off preference.

## Engineering boundaries

`AppStore.swift` is currently a large coordinator. Gateway address policy lives
in `HermesAddress`; conversation archives in `ConversationArchive`; bot layout
in `BotChannel`. New networking, parsing and domain behavior should prefer
focused modules with explicit inputs. Extract existing behavior only with
regression coverage; do not split files just to hide coupling. The legacy web
transport files need the same restraint.

UI components should display facts from those services, show actionable failures
and retain useful state during retries. Capability detection must distinguish
absence from failed detection. Test the boundary, then test the user's journey.

Agent Maker is identified by `ui_meta.alice.role = agent-maker`, with a legacy
fallback to the profile `forja`. Alice mints a new profile from a sentence
(`AgentDraft`) through the same engine Agent Maker uses
(`hermes-plugin/agent_engine.py`): a validated spec, structured result, and
official Hermes CLI (`profile create` / `profile rename`). `reuse_profile`
requires the same `job_id` that created the profile; a foreign profile is left
intact. `job_id` is a journal stem only (no paths). Partial results keep their
error and `job_id` for recovery; Alice does not send the person's brief until
`status` is `completed`. Rename checks Hermes session leases and in-flight writes on the server.
Alice will not start a Hermes directory rename: sessions keep `registry_home` on
the old profile path, and Hermes has no coordination outside that directory and
no identity check those sessions respect. A same-id title update still runs.
A journal whose directory move already landed can finish rebinding. The
operations journal is rewritten to the status that is actually returned
(`completed` is never left behind after a `partial`). A client `busy` flag is
not enough. The iPhone form and the Agent Maker conversation stay as they are; they
no longer diverge on collision, model, or tools.

`hermes-agents/forja` and `hermes-plugin/tests/test_agent_engine.py` check the
engine against a fake Hermes CLI so those tests do not send prompts to a
person's agent.
