# Alice for Hermes

A Hermes plugin with what the Alice iPhone app needs from a Hermes and Hermes itself
does not ship. It lives in `~/.hermes/plugins/alice`, outside Hermes' own code, so
`hermes update` never collides with it.

What it adds, all in the dashboard:

- An **Alice** tab that shows a one-time pairing QR code (`docs/pairing.md`).
- `POST /api/plugins/alice/pairing/session` — behind the dashboard login; mints the QR
  and, when the main profile has no gateway yet, provisions one.
- `POST /api/plugins/alice/pairing/claim` — the phone exchanges the QR's one-time code for
  the gateway and dashboard credentials. Authenticated through Hermes' token-auth seam
  (`Authorization: Bearer <code>`); only loopback and Tailscale addresses may claim.
- `GET` / `POST /api/plugins/alice/memory` — read and edit a profile's curated memory
  (MEMORY.md / USER.md), behind the dashboard login.

The agent gains nothing: no tools, hooks or commands.

## Install

From a checkout of this repository:

```bash
cp -R hermes-plugin ~/.hermes/plugins/alice
hermes plugins enable alice --no-allow-tool-override
```

Then restart the dashboard (on macOS with the launchd service:
`launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard`).

## Develop

- Backend tests (Hermes' virtualenv):
  `~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests`
- The tab is `dashboard/src/index.js`, bundled into `dashboard/dist/index.js` by
  `build.sh` (see the script for the one-time `qrcode` install). Commit the rebuilt
  bundle and `dist/THIRD_PARTY_LICENSES.txt` together.
