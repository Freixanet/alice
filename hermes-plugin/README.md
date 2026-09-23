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
  (MEMORY.md / USER.md), behind the dashboard login. `GET` also returns `origins`, one per
  entry in the same order: who wrote it (`agent`, `person`, `hand`, `legacy`), when, and in
  which session and profile. Edits made here are recorded as the person's.
- **Memory that keeps itself tidy** (`memory_keeper.py`) — see below:
  `GET /api/plugins/alice/memory/maintenance?profile=` (what cleanup would change now, and
  what it has changed), `PUT …/memory/maintenance` `{profile, apply?, learn?}` (turn applying
  cleanup on or off, off by default; and learning from conversations, on by default), `POST …/memory/maintenance/run` `{profile}` (a pass now),
  `POST …/memory/changes/{id}/revert` `{profile}` (put back what one change removed) and
  `GET …/memory/origin?profile=&target=&text=` (or `&entry=<id>`: "why do you know this?").
- `GET` / `POST /api/plugins/alice/notes` — Alice's Notes: list and add to the notes store
  an agent keeps in `workspace/inbox-store` (the Inbox agent's; a remembered profile in
  `~/.hermes/.alice/notes_store.json`, else `inbox`, else the first profile with a store),
  behind the dashboard login. Notes are added through the store's own `inbox.py add`, so the
  store stays append-only; `GET` reports `available: false` when no agent keeps one.
- `POST /api/plugins/alice/agents` and `POST /api/plugins/alice/agents/rename` — the shared
  agent engine Alice's form and Agent Maker both use. Create and rename go through official
  Hermes profile commands, with a structured result (`completed`, `partial`, `needs_auth`,
  `failed`). A taken name is left unchanged. Agent Maker also gets `agent_create` and
  `agent_rename` tools, visible only on the stamped `agent-maker` role (legacy `forja`
  included).

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
  cli: [web, file, skills, memory, clarify, todo, notes] # `terminal` is no longer needed
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

## Memory that keeps itself tidy

Hermes keeps curated memory as plain `MEMORY.md` / `USER.md` files: entries separated by
`§`, with no date, origin or id. The plugin leaves those files exactly as Hermes writes them
and keeps its own record in `<profile home>/.alice/memory/`:

- `entries.json` — where each entry came from, keyed by a hash of its text: an **agent**
  (recorded by the `post_tool_call` hook on `memory`, with its session and profile), the
  **person** (edits through `POST /memory`), **hand** (appeared in the file outside both — an
  edit by hand), or **legacy** (already there the first time the plugin looked; no history,
  still works as before).
- `changes.json` — every change cleanup made, with the full text it removed. Any change can
  be reverted; nothing is deleted without a trace. A reverted change is never proposed again.
- `settings.json` — `apply`. **Off by default: cleanup only proposes.** And `learn`, on by
  default (below).
- `reviewed.json` — for each conversation, the last message already read for facts.

Cleanup runs after each agent write to memory and on demand, and is conservative on
purpose. It only acts on:

1. **Clear duplicates** — the same entry again, ignoring case, spacing and final punctuation.
   The oldest copy stays.
2. **Dated events that have passed** — an entry about an appointment, flight, deadline… whose
   every explicit date is more than a day behind. A fact with a date in it ("born on…") does
   not expire.
3. **"Ya no…" contradictions** — a newer entry saying something is no longer so retires the
   older entry that says it is; the "ya no" stays.

Anything doubtful is left alone. Entries from the person or edited by hand are never touched
by any rule; legacy entries only take part in exact duplicates and in dates that name the
year. Every write goes through Hermes' own `MemoryStore` (its lock, atomic writes and size
limit); a revert that no longer fits the limit says so and changes nothing.

### What the person said and no agent kept

Hermes' agent saves to memory when it notices something, and reviews the conversation every
few turns (`memory.nudge_interval`). A short exchange ("vivo en Súria", two turns) can end
before either happens. `memory_review.py` closes that gap: every finished turn
(`on_session_end`) restarts a 90-second wait for its conversation; once it is quiet, the
plugin reads **only the person's own messages** since the last look — never the agent's
replies, never routines (`cron`), never internal profiles — and asks the profile's own model
(or `auxiliary.alice_memory_review`, if set) for durable facts about them. A fact is kept
only when:

- its `evidence` is the person's words, and they are really in one of their messages (case,
  spacing and Markdown marks aside; fragments joined by "…" must appear in order);
- it is short, one entry, and not already in memory;
- if it updates an entry, that entry is named exactly and was not written by the person or
  by hand.

Each fact kept is a `learned` change in `changes.json`, with its session and evidence, and
an origin of `learned`; reverting it removes the fact and puts back what it replaced. Each
message is read once. At most five facts per look.

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
