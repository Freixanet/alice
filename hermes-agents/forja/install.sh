#!/bin/zsh
# Installs Forja, the agent that creates agents, into this Mac's Hermes.
#
#   hermes-agents/forja/install.sh [--sin-atajo]
#
# Creates the `forja` agent with its own creation script (checked first, then
# for real), then copies its skill into the profile. Refuses if `forja` already
# exists; never changes or deletes another agent. Honours HERMES_HOME.
set -euo pipefail

here=${0:A:h}
hermes_home=${HERMES_HOME:-$HOME/.hermes}
py=$HOME/.hermes/hermes-agent/venv/bin/python
[[ -x $py ]] || { print -u2 "Hermes was not found at ~/.hermes/hermes-agent."; exit 1; }

spec=$(mktemp -t forja-spec)
trap 'rm -f "$spec"' EXIT
"$py" - "$here/SOUL.md" "$spec" <<'EOF'
import json, sys
from pathlib import Path
soul, out = Path(sys.argv[1]), Path(sys.argv[2])
out.write_text(json.dumps({
    "name": "forja",
    "title": "Forja",
    "description": "Crea agentes a medida: entiende lo que necesitas, te pregunta lo justo y deja el agente funcionando y visible en Alice.",
    "soul": soul.read_text(encoding="utf-8"),
    "tools": ["terminal"],
    "routines": [],
}, ensure_ascii=False), encoding="utf-8")
EOF

script=$here/skill/forja-crear-agentes/scripts/crear_agente.py
"$py" "$script" "$spec" --comprobar
"$py" "$script" "$spec" "$@"

dest=$hermes_home/profiles/forja/skills/productivity/forja-crear-agentes
mkdir -p "$dest"
cp -R "$here/skill/forja-crear-agentes/." "$dest/"
print "Forja is installed. In Alice it is under Agents → Home."
