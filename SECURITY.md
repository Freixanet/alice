# Security

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](https://github.com/Freixanet/alice/security/advisories/new)
rather than opening a public issue. Expect a first response within a week.

## Threat model

Alice is a front end for an agent that can read files, run commands and spend
money on your behalf. The connection key to that agent is the asset worth
protecting, so it never enters this repository and never reaches the browser as
readable text.

**Where the key lives**

| Deployment                   | Storage                                                  | Readable by the page |
| ---------------------------- | -------------------------------------------------------- | -------------------- |
| Server (Vercel, self-hosted) | Encrypted in an `httpOnly` cookie, decrypted per request | No                   |
| Same machine as the agent    | Process memory for the lifetime of the tab               | No                   |

Set `HERMES_COOKIE_SECRET` to a long random value in any deployment you keep.
Without it the cookie is encrypted with a key that dies with the process, so
every restart forces a reconnect.

**What Alice does not do**

- It never writes the key to `localStorage`, to the DOM, or to a log line.
- It never echoes a key back in an API response, including on errors.
- It never sends the key anywhere but the Hermes address you configured.

**What Alice cannot protect you from**

The agent runs with your privileges on the machine that hosts it. Anyone who
can reach that agent's address with a valid key can act as you. Do not expose a
Hermes endpoint publicly without a key, and treat the address as sensitive.

## Supply chain

Every push runs `gitleaks` over the full history, `npm audit --audit-level=high`,
and a dependency check that fails on unlisted or unused packages.
