# Alice for Hermes

A Hermes plugin with what the Alice iPhone app needs from a Hermes and Hermes itself
does not ship. It lives in `~/.hermes/plugins/alice`, outside Hermes' own code.
Updates do not overwrite Hermes source, but upstream API changes still need a
compatibility check.

What it adds, all in the dashboard:

- An **Alice** tab that shows a one-time pairing QR code ([protocol](../docs/pairing.md)).
- `POST /api/plugins/alice/pairing/session` — behind the dashboard login; mints the QR
  and, when the main profile has no gateway yet, provisions one.
- `POST /api/plugins/alice/pairing/claim` — the phone exchanges the QR's one-time code for
  the gateway and dashboard credentials. Authenticated through Hermes' token-auth seam
  (`Authorization: Bearer <code>`); only loopback and Tailscale addresses may claim.
- `GET` / `POST /api/plugins/alice/memory` — read and edit a profile's curated memory
  (MEMORY.md / USER.md), behind the dashboard login.
- `GET` / `POST /api/plugins/alice/notes` — Alice's Notes: list and add to the notes store
  an agent keeps in `workspace/inbox-store` (the Inbox agent's; `inbox` first, else the
  first profile with one), behind the dashboard login. Notes are added through the store's
  own `inbox.py add`, so the store stays append-only; `GET` reports `available: false`
  when no agent keeps one.

It also gives a note-taking agent a **`notes` toolset** for the store it keeps in
`workspace/inbox-store`: `note_add`, `note_file`, `note_folders`, `note_folder_create`,
`note_folder_rename`, `note_folder_delete`, `note_get`, `note_search`, `note_recent`,
`note_similar`, `note_unprocessed`, `note_enrich`, `note_mark_processed`,
`note_digest_week` and `note_relate`. Each one is the `inbox.py` command of the same name,
called in-process. The agent used to reach the store through the terminal, which meant a
note's text arrived as a heredoc piped into an interpreter — exactly what the security
scanner stops, so every capture waited for approval. As tools there is no shell to scan,
no quoting to get wrong and no interpreter to start. A profile without that store sees
none of these tools (`check_fn`), so enable the `notes` toolset only where the store is:

```yaml
platform_toolsets:
  cli: [web, file, skills, memory, clarify, todo, notes]   # `terminal` is no longer needed
```

The agent gains one rule:

- **The Business team talks only among itself.** A `pre_tool_call` hook on `message_agent`
  lets a profile filed in the Business channel (`ui_meta['alice'].channel`, written by
  `hermes-agents/business-team/instalar.py`) message only teammates in that channel, and
  blocks anyone outside it, Alice included, from messaging them. Agents outside Business
  keep talking to each other. A system prompt section (`alice.equipos`) tells each agent
  whom it may message, so it does not try the others. Internal profiles (`ui_meta['alice'].internal`, such as
  Evals' sandbox) neither send nor receive messages. If the rule cannot be checked, the
  message does not go.
  The hook runs only in profiles where the plugin is enabled; the team installer enables
  it in every profile.

## Install

From a checkout of this repository, one command:

```bash
hermes-plugin/install.sh
```

It copies the plugin to `~/.hermes/plugins/alice`, enables it, and restarts the
macOS dashboard service when that service exists. Then restart any running
gateway: Hermes loads plugins once per process.

To do the same steps by hand:

```bash
mkdir -p ~/.hermes/plugins/alice
cp -R hermes-plugin/. ~/.hermes/plugins/alice/
hermes plugins enable alice --no-allow-tool-override
```

Then restart the dashboard (on macOS with the launchd service:
`launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard`) and any running gateway.

## Develop

- Backend tests (Hermes' virtualenv):
  `~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests`
- The tab is `dashboard/src/index.js`, bundled into `dashboard/dist/index.js` by
  `build.sh` (see the script for the one-time `qrcode` install). Commit the rebuilt
  bundle and `dist/THIRD_PARTY_LICENSES.txt` together.
