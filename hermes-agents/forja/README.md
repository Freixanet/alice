# Agent Maker — the agent that creates agents

A Hermes agent that designs and creates other agents end to end. It works out
what you need, asks multiple-choice questions only when the answer changes the
agent (Hermes' `clarify` tool, which Alice shows), shows a short plan, and after
you confirm creates the agent and makes it appear in Alice.

Alice identifies it by a stamped role (`ui_meta.alice.role = agent-maker`), not
a fixed slug. Older installs still live at `forja`. A fresh install creates
`agent-maker`. Renaming Agent Maker also renames its Hermes profile; Alice keeps
finding it. That migration is never run automatically.

## What is here

- `SOUL.md` — Agent Maker's instructions (mandatory intake, examples, rewrite
  an Alice-minted profile instead of creating a second one).
- `skill/forja-crear-agentes/` — the procedure (`SKILL.md`), a design guide
  (`references/guia-agentes.md`) and `scripts/crear_agente.py`, a thin CLI over
  the shared engine in `hermes-plugin/agent_engine.py`.
- `tests/` — the creator script against a fake Hermes CLI. Does not talk to a
  live agent. The engine tests live in `hermes-plugin/tests/test_agent_engine.py`.
- `install.sh` — installs Agent Maker. If `forja` or `agent-maker` already
  exists, only the skill is refreshed and the role is stamped; the profile is
  left in place.

## Install

```bash
hermes-agents/forja/install.sh
```

Agent Maker then appears in Alice under Agents → Home. Run the same command
again after changing the skill; it will not recreate the agent and will not
rename `forja`.

To try it without touching your Hermes:

```bash
python3 hermes-plugin/tests/test_agent_engine.py
python3 hermes-agents/forja/tests/test_crear_agente.py
```

`install.sh --sin-atajo` with a throwaway `HERMES_HOME` still talks to this
Mac's Hermes Python; the tests above do not.

## Shared engine

Alice's form and Agent Maker call the same writer: profile identity, SOUL with
examples, chosen model and provider (no silent fallback), tools and skills the
design asked for, optional authorized memory, confirmed routines, Alice
metadata, and a journalled result (`completed`, `partial`, `needs_auth`,
`verification_failed`, `failed`). A taken name fails; a retry with the same
`job_id` does not mint a second profile. Rename uses official
`hermes profile rename`.
