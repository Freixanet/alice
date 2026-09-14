# Forja — the agent that creates agents

A Hermes agent that designs and creates other agents end to end. It works out
what you need, asks multiple-choice questions only when the answer changes the
agent (Hermes' `clarify` tool, which Alice shows), shows a short plan, and after
you confirm creates the agent and makes it appear in Alice.

## What is here

- `SOUL.md` — Forja's instructions.
- `skill/forja-crear-agentes/` — the procedure (`SKILL.md`), a design guide
  (`references/guia-agentes.md`) and `scripts/crear_agente.py`, which creates an
  agent with Hermes' own commands (`hermes profile create`, `hermes config set`,
  `hermes cron create`), writes its instructions and its name in Alice, then
  checks everything. It never changes or deletes an agent that already exists.
- `install.sh` — installs Forja into this Mac's Hermes.

## Install

```bash
hermes-agents/forja/install.sh
```

Forja then appears in Alice under Agents → Home.

To try it without touching your Hermes:

```bash
HERMES_HOME="$(mktemp -d)" hermes-agents/forja/install.sh --sin-atajo
```

## Defaults

Agents Forja creates use this installation's standard: Muse Spark 1.3
(`opencode-free`) with ChatGPT Luna (`openai-codex`) as fallback, and they always
keep the `clarify` tool. For another setup, change `MODEL` and `FALLBACK` at the
top of `crear_agente.py`. `SKILL.md` points at the default Hermes location
(`~/.hermes`).
