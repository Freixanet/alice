#!/bin/zsh
# Installs Agent Maker, the agent that creates agents, into this Mac's Hermes.
#
#   hermes-agents/forja/install.sh [--sin-atajo]
#
# Creates the `forja` agent with its own creation script (checked first, then
# for real), then copies its skill into the profile. If `forja` already exists,
# only the skill is refreshed; the profile, instructions and tools are left
# alone. Never changes or deletes another agent. Honours HERMES_HOME.
set -euo pipefail

here=${0:A:h}
hermes_home=${HERMES_HOME:-$HOME/.hermes}
py=$HOME/.hermes/hermes-agent/venv/bin/python
[[ -x $py ]] || { print -u2 "Hermes was not found at ~/.hermes/hermes-agent."; exit 1; }

dest=$hermes_home/profiles/forja/skills/productivity/forja-crear-agentes
install_skill() {
  mkdir -p "$dest"
  cp -R "$here/skill/forja-crear-agentes/." "$dest/"
}

if [[ -d $hermes_home/profiles/forja && -f $hermes_home/profiles/forja/config.yaml ]]; then
  install_skill
  print "Agent Maker already exists; its skill is up to date. In Alice it is under Agents → Home."
  exit 0
fi

spec=$(mktemp -t forja-spec)
trap 'rm -f "$spec"' EXIT
"$py" - "$here/SOUL.md" "$spec" <<'EOF'
import json, sys
from pathlib import Path
soul, out = Path(sys.argv[1]), Path(sys.argv[2])
out.write_text(json.dumps({
    "name": "forja",
    "title": "Agent Maker",
    "description": "Creates agents to spec: understands what you need, asks only what changes the result, and leaves the agent running and visible in Alice.",
    "soul": soul.read_text(encoding="utf-8"),
    "tools": ["terminal"],
    "routines": [],
}, ensure_ascii=False), encoding="utf-8")
EOF

script=$here/skill/forja-crear-agentes/scripts/crear_agente.py
"$py" "$script" "$spec" --comprobar
"$py" "$script" "$spec" "$@"

install_skill
print "Agent Maker is installed. In Alice it is under Agents → Home."
