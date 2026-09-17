#!/bin/zsh
# Installs Agent Maker, the agent that creates agents, into this Mac's Hermes.
#
#   hermes-agents/forja/install.sh [--sin-atajo]
#
# A fresh install creates `agent-maker`. If `forja` already exists, only the
# skill is refreshed and the agent-maker role is stamped; the profile is not
# renamed. Never changes or deletes another agent. Honours HERMES_HOME.
# Does not migrate forja → agent-maker; that is an explicit rename.
set -euo pipefail

here=${0:A:h}
hermes_home=${HERMES_HOME:-$HOME/.hermes}
py=$HOME/.hermes/hermes-agent/venv/bin/python
plugin=$here/../../hermes-plugin
[[ -x $py ]] || { print -u2 "Hermes was not found at ~/.hermes/hermes-agent."; exit 1; }

profile=""
if [[ -d $hermes_home/profiles/forja && -f $hermes_home/profiles/forja/config.yaml ]]; then
  profile=forja
elif [[ -d $hermes_home/profiles/agent-maker && -f $hermes_home/profiles/agent-maker/config.yaml ]]; then
  profile=agent-maker
fi

install_skill() {
  dest=$hermes_home/profiles/$1/skills/productivity/forja-crear-agentes
  mkdir -p "$dest"
  cp -R "$here/skill/forja-crear-agentes/." "$dest/"
  if [[ -f $plugin/agent_engine.py ]]; then
    cp "$plugin/agent_engine.py" "$dest/scripts/agent_engine.py"
  fi
}

stamp_role() {
  "$py" - "$plugin" "$hermes_home/profiles/$1" <<'EOF'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import agent_engine
agent_engine.stamp_maker_role(Path(sys.argv[2]))
EOF
}

if [[ -n $profile ]]; then
  install_skill "$profile"
  stamp_role "$profile"
  print "Agent Maker already exists as \`$profile\`; its skill is up to date. In Alice it is under Agents → Home."
  print "Renaming it to Agent Maker (profile \`agent-maker\`) is a separate, explicit step."
  exit 0
fi

spec=$(mktemp -t agent-maker-spec)
trap 'rm -f "$spec"' EXIT
"$py" - "$here/SOUL.md" "$spec" <<'EOF'
import json, sys
from pathlib import Path
soul, out = Path(sys.argv[1]), Path(sys.argv[2])
out.write_text(json.dumps({
    "name": "agent-maker",
    "title": "Agent Maker",
    "description": "Creates agents to spec: understands what you need, asks only what changes the result, and leaves the agent running and visible in Alice.",
    "soul": soul.read_text(encoding="utf-8"),
    "tools": ["terminal", "clarify"],
    "routines": [],
    "role": "agent-maker",
    "source": "maker",
}, ensure_ascii=False), encoding="utf-8")
EOF

script=$here/skill/forja-crear-agentes/scripts/crear_agente.py
"$py" "$script" "$spec" --comprobar
"$py" "$script" "$spec" "$@"

install_skill agent-maker
stamp_role agent-maker
print "Agent Maker is installed as \`agent-maker\`. In Alice it is under Agents → Home."
