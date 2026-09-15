# Hermes 0.21 contract compatibility

Alice's current stable API fixture is `0.21.3` (14 September 2026), with
regression fixtures for `0.21.2`, `0.21.0` and `0.20.6`. The static capability
flags and 28 HTTP endpoints were checked against `gateway/platforms/api_server.py`
at the official `v2026.9.14` and `v2026.9.11` tags. This verifies those contracts,
not every live configuration, integration or future release.

The following is the release-delta checklist for Pantheon, based on the official
[`v2026.8.31` release](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.8.31)
and the corresponding Hermes source contracts.

## Compatibility rules

- Runtime capabilities that already travel through the Hermes chat protocol
  must remain transparent. Alice must not filter tools, providers, models,
  browser-control calls, delegation events, structured outputs, or tool results.
- Alice adds native controls only for operations Hermes exposes through a stable
  HTTP or gateway contract. It must not invent routes for desktop-only state.
- Every native control is version- or capability-gated and degrades independently.
- Pantheon additions must work through both Alice transports: direct browser to
  Hermes and Alice's authenticated server proxy.

## Release delta

| Pantheon area                                      | Alice exposure                                                                          | Contract/status                                                       |
| -------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| New providers, models and model overrides          | Dynamic model discovery and chat payloads                                               | Transparent; no allowlist                                             |
| Tool calls, browser control and structured results | Chat event stream                                                                       | Transparent                                                           |
| Live subagent activity                             | `subagent.start` / `subagent.complete` stream events plus run steering and cancellation | Native where advertised                                               |
| Cron continuity                                    | Scheduled-job editor                                                                    | Native in `0.21.0` (`context_from: ["self"]`)                         |
| Cron monitor mode                                  | Scheduled-job editor                                                                    | Native in `0.21.0` (script or HTTP(S) URL)                            |
| Per-job reasoning effort                           | Scheduled-job editor                                                                    | Native in `0.21.0`                                                    |
| Durable cron notepad                               | Managed automatically by Hermes                                                         | Transparent; surfaced as an explanatory invariant                     |
| MCP server lifecycle                               | Add, enable, test and remove                                                            | Native                                                                |
| MCP catalog, OAuth, health and schema-cost data    | Progressive MCP command center with 30-day usage                                        | Native in `0.21.0`; direct and authenticated-proxy transports         |
| Bot Mode identities and canonical chats            | Agents page with profile-bound conversations                                            | Native; the owning profile is persisted per conversation              |
| Hosted group rooms and group turns                 | Agents → Group chats                                                                    | Native through the official `groups.*` JSON-RPC gateway               |
| `hermes peer` durable agent DMs                    | Hermes chat/tool protocol plus RoomLink capability negotiation                          | Transparent; ordinary room use never assumes peer support             |
| Generated files, images, links and code            | Artifacts page                                                                          | Rebuilt safely from durable transcripts; content is never executed    |
| Usage, model, skill and tool analytics             | Insights page                                                                           | Native through `/api/analytics/usage`, scoped to the selected profile |
| Caching, security and reliability changes          | Hermes runtime                                                                          | Transparent                                                           |

## Required gates

- Contract fixtures cover `0.21.3`, `0.21.2`, `0.21.0` and `0.20.6`.
- Pantheon Cron create is atomic from Alice's perspective: if the follow-up
  update fails, Alice removes only the job it just created.
- Unknown or older Hermes versions never receive unadvertised Pantheon fields.
- Direct and proxy transports preserve the same request/response semantics.
- MCP health probes run after first paint, use a five-minute profile-scoped
  cache and never exceed two concurrent checks.
- Catalog credentials are bounded, sent only for installation and cleared from
  the UI on completion or close. OAuth authorization is explicit and polled by
  opaque flow ID; Alice never opens a provider URL without a user action.
