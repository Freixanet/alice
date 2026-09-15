# Security

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](https://github.com/Freixanet/alice/security/advisories/new)
rather than opening a public issue. Include the affected version, reproduction
steps and impact, without live credentials or private conversations.

## Threat model

Alice is a front end for an agent that can read files, run commands and spend
money on your behalf. The connection key to that agent is the asset worth
protecting. Do not commit real credentials. The browser can read credentials
entered into the connection form, and needs the gateway key for direct mode.

**Where the key lives**

| Transport      | Stored credential                                                    | Trust boundary                                                                                 |
| -------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Server proxy   | Encrypted `httpOnly` connection cookie                               | Alice's server decrypts the key to contact Hermes; JavaScript cannot read the cookie.          |
| Direct browser | Account-scoped `sessionStorage` plus the encrypted connection cookie | The authenticated `device-secret` API returns the key to the browser so it can contact Hermes. |
| Local Mac      | Server access to local Hermes and optional browser memory            | Only the configured owner may use local access with authentication enabled.                    |
| iPhone         | `WhenUnlockedThisDeviceOnly` Keychain                                | Readable by the app when the device is unlocked; no separate biometric prompt is required.     |

Set `HERMES_COOKIE_SECRET` to a long random value in any deployment you keep.
Production requires a persistent encryption key (`HERMES_COOKIE_SECRET`,
`HERMES_COOKIE_KEYS`, or the `BETTER_AUTH_SECRET` fallback). Development can
create a persistent key file at `~/.alice/hermes-credential.key`.

**What Alice does not do**

- It does not persist the gateway key in `localStorage` or intentionally log it.
- Server proxy mode sends credentials through Alice's server; direct mode sends
  them from the browser to the configured Hermes origin.
- Native requests and redirects are restricted to the configured service origin.

An injected script or compromised dependency running in the browser can access
direct-mode credentials and decrypted conversations. Encryption at rest does
not protect against code running inside an unlocked, authenticated client.
The pairing QR contains a short-lived bearer secret; anyone holding it who can
reach the allowed network can claim it once. See [pairing](docs/pairing.md).

**What Alice cannot protect you from**

The agent runs with your privileges on the machine that hosts it. Anyone who
can reach that agent's address with a valid key can act as you. Do not expose a
Hermes endpoint publicly without a key, and treat the address as sensitive.

## Supply chain

Every push runs `gitleaks` over the full history, `npm audit --audit-level=high`,
and a dependency check that fails on unlisted or unused packages.
