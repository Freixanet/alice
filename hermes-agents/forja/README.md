# Agent Maker — the agent that creates agents

A Hermes agent (`forja`) that designs and creates other agents end to end. It
works out what you need, asks multiple-choice questions only when the answer
changes the agent (Hermes' `clarify` tool, which Alice shows), shows a short
plan, and after you confirm creates the agent and makes it appear in Alice.

## What is here

- `SOUL.md` — Agent Maker's instructions (mandatory intake, examples, rewrite
  an Alice-minted profile instead of creating a second one).
- `skill/forja-crear-agentes/` — the procedure (`SKILL.md`), a design guide
  (`references/guia-agentes.md`) and `scripts/crear_agente.py`, which creates an
  agent with Hermes' own commands (`hermes profile create`, `hermes config set`,
  `hermes cron create`), writes its instructions (examples required) and its
  name in Alice, then checks files and runs a one-question smoke test. It never
  changes or deletes an agent that already exists.
- `tests/` — the same script against a fake Hermes CLI. Does not talk to a
  live agent.
- `install.sh` — installs Agent Maker into this Mac's Hermes. If the `forja`
  profile already exists, it only refreshes the skill; the profile is left
  alone.

## Install

```bash
hermes-agents/forja/install.sh
```

Agent Maker then appears in Alice under Agents → Home. Run the same command
again after changing the skill; it will not recreate the agent.

To try it without touching your Hermes:

```bash
python3 hermes-agents/forja/tests/test_crear_agente.py
```

`install.sh --sin-atajo` with a throwaway `HERMES_HOME` still talks to this
Mac's Hermes Python; the tests above do not.

## Defaults

Agents that Agent Maker creates use Muse Spark 1.3 (`opencode-free`) with
ChatGPT Luna (`openai-codex`) as fallback, and they always keep the `clarify`
tool. Override with `HERMES_HOME`, `HERMES_BIN`, `ALICE_AGENT_MODEL` and
`ALICE_AGENT_FALLBACK`. `--sin-humo` skips the one-question smoke test.
