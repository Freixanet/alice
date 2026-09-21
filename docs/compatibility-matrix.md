# Compatibility and readiness

Alice's primary product is the iOS app. This table identifies implementation
boundaries; it is not a promise that every deployment has passed live testing.

| Area                        | iOS                                                                                                                                                                                       | Web                              | Dependency / validation boundary                                                |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------- |
| Chat and streaming          | Native                                                                                                                                                                                    | Direct + proxy                   | Reachable, authenticated Hermes gateway                                         |
| Agents / canonical sessions | Native; create/rename share the plugin engine; reuse needs the job that minted the profile; directory identity change is refused until Hermes can coordinate it outside the moved profile | Companion controls               | Dashboard RPC, plugin `/agents`, and profile identity                           |
| Pairing QR                  | Native scanner and deep link                                                                                                                                                              | Manual connection                | Alice plugin; current provisioning targets macOS + Tailscale                    |
| Models / providers          | Dynamic catalog; an agent’s page sets its primary model and fallback                                                                                                                      | Dynamic catalog                  | Permissions and configured upstream provider; fallback is GET/PUT `/api/config` |
| Routines                    | Native                                                                                                                                                                                    | Native controls                  | Version/capability-gated fields; remote jobs are authoritative                  |
| MCP / skills / tools        | Native management views                                                                                                                                                                   | Companion views                  | Individual management endpoints and configured integrations                     |
| Notes                       | Native                                                                                                                                                                                    | No equivalent primary notes page | An agent's compatible inbox-store must exist                                    |
| Memory / projects / files   | Native management                                                                                                                                                                         | Partial companion surfaces       | Dashboard/plugin contracts vary by feature                                      |
| Notifications               | Local + opportunistic background refresh; Live Activity for home and bot chats while Alice runs                                                                                           | Browser/session behavior         | iOS controls background execution; no always-on guarantee; no APNs              |
| Share into chat             | Share extension hands Alice a paragraph or URL as a composer draft                                                                                                                        | No                               | Person sends; extension does not talk to Hermes                                 |
| Encrypted conversation sync | Not a shared native sync implementation                                                                                                                                                   | Account-scoped E2EE              | Do not claim iOS/web cloud-sync parity                                          |
| Account sign-in             | Direct Hermes credentials                                                                                                                                                                 | Alice accounts                   | Separate identity and recovery responsibilities                                 |

## Verified contract versions

The web API fixtures cover Hermes **0.21.3**, **0.21.2**, **0.21.0** and **0.20.6**.
Source tags and commits are stored in `src/lib/hermes-contract-fixtures.ts`.
The checked 0.21 family retains Pantheon controls across those patch versions.
Unknown versions must continue to use independently advertised capabilities.
See [the detailed contract checklist](hermes-contracts.md).

## Remaining release qualifications

- A clean install still needs a running, configured Hermes. Manual address
  and key work on any reachable host. QR provisioning still expects the Alice
  plugin and is not a universal installer for Windows, Linux or every cloud
  dashboard.
- Production web account recovery and verification need an operational email
  delivery flow; login tests with authentication disabled do not prove it.
- Physical-device pairing, suspension/recovery and end-to-end agent operations
  need a healthy test Hermes and must be recorded for the release candidate.
- Broader Hermes updates may add management contracts beyond the HTTP fixtures.
  Revisit this matrix after each upstream release; do not infer total parity from
  a version string or the ability to send a chat message.
- The iOS share extension forwards text or one URL into the composer. It has not
  been live-tested from Safari on a physical iPhone in this change set.

## A fixture is not a client implementation

The source fixtures describe Hermes' advertised HTTP surface. They do not imply
that Alice implements a separate client for every wire protocol. For example,
`/v1/responses` is recorded in the fixture, while Alice's conversations use its
chat, run and dashboard RPC transports. The browser-control registration/socket
endpoints are also recorded, but Alice does not implement a device-browser bridge
for them. Hermes can still use browser tools on its own host; that is a different
execution surface.

Native dictation and read-aloud use the iOS speech interfaces. They do not imply
support for a Hermes realtime-voice service: the checked static manifest marks
`audio_api` and `realtime_voice` false. Review new advertised features individually
instead of treating a fixture version as a universal compatibility certificate.
