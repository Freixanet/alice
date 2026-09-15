# Compatibility and readiness

Alice's primary product is the iOS app. This table identifies implementation
boundaries; it is not a promise that every deployment has passed live testing.

| Area                        | iOS                                      | Web                              | Dependency / validation boundary                               |
| --------------------------- | ---------------------------------------- | -------------------------------- | -------------------------------------------------------------- |
| Chat and streaming          | Native                                   | Direct + proxy                   | Reachable, authenticated Hermes gateway                        |
| Agents / canonical sessions | Native                                   | Companion controls               | Dashboard RPC and profile identity                             |
| Pairing QR                  | Native scanner and deep link             | Manual connection                | Alice plugin; current provisioning targets macOS + Tailscale   |
| Models / providers          | Dynamic catalog                          | Dynamic catalog                  | Permissions and configured upstream provider                   |
| Routines                    | Native                                   | Native controls                  | Version/capability-gated fields; remote jobs are authoritative |
| MCP / skills / tools        | Native management views                  | Companion views                  | Individual management endpoints and configured integrations    |
| Notes                       | Native                                   | No equivalent primary notes page | An agent's compatible inbox-store must exist                   |
| Memory / projects / files   | Native management                        | Partial companion surfaces       | Dashboard/plugin contracts vary by feature                     |
| Notifications               | Local + opportunistic background refresh | Browser/session behavior         | iOS controls background execution; no always-on guarantee      |
| Encrypted conversation sync | Not a shared native sync implementation  | Account-scoped E2EE              | Do not claim iOS/web cloud-sync parity                         |
| Account sign-in             | Direct Hermes credentials                | Alice accounts                   | Separate identity and recovery responsibilities                |

## Verified contract versions

The web API fixtures cover Hermes **0.21.3**, **0.21.2**, **0.21.0** and **0.20.6**.
Source tags and commits are stored in `src/lib/hermes-contract-fixtures.ts`.
The checked 0.21 family retains Pantheon controls across those patch versions.
Unknown versions must continue to use independently advertised capabilities.
See [the detailed contract checklist](../HERMES_PANTHEON.md).

## Remaining release qualifications

- A clean install still needs a running, configured Hermes. QR provisioning is
  not yet a universal installer for Windows, Linux or every cloud dashboard.
- Production web account recovery and verification need an operational email
  delivery flow; login tests with authentication disabled do not prove it.
- Physical-device pairing, suspension/recovery and end-to-end agent operations
  need a healthy test Hermes and must be recorded for the release candidate.
- Broader Hermes updates may add management contracts beyond the HTTP fixtures.
  Revisit this matrix after each upstream release; do not infer total parity from
  a version string or the ability to send a chat message.
