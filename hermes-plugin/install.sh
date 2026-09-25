#!/bin/zsh
# Installs the Alice dashboard plugin into this machine's Hermes.
#
#   hermes-plugin/install.sh
#
# Copies the plugin, enables it, and restarts the macOS dashboard service when
# it is present. Chat still works without this; the Alice tab and pairing QR
# need it. Honours HERMES_HOME.
set -euo pipefail

here=${0:A:h}
hermes_home=${HERMES_HOME:-$HOME/.hermes}
dest=$hermes_home/plugins/alice

if ! command -v hermes >/dev/null; then
  print -u2 "The hermes command was not found. Install Hermes first."
  exit 1
fi

mkdir -p "$dest"
# Skills are left read-only (below); an update replaces them.
[[ -d $dest/skills ]] && chmod -R u+w "$dest/skills"
cp -R "$here/." "$dest/"

# pypdf (BSD) for PDF forms, into the plugin's own folder: Hermes' environment is not touched.
python=$hermes_home/hermes-agent/venv/bin/python
[[ -x $python ]] || python=$(command -v python3)
if ! "$python" -m pip install --quiet --upgrade --target "$dest/vendor" 'pypdf==6.18.0'; then
  print -u2 "Could not install pypdf; PDF forms will ask for it until the plugin is installed again."
fi
hermes plugins enable alice --no-allow-tool-override

# The plugin's own skills (skills/comprar) in Hermes' skill list, read-only: they are the
# rules the plugin injects, so an agent must not rewrite them. An existing list is kept.
chmod -R a-w "$dest/skills"/*/SKILL.md
skills_dir="$dest/skills"
current=$("$python" - "$hermes_home/config.yaml" <<'PY' 2>/dev/null || true
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except OSError:
    cfg = {}
print("\n".join(str(d) for d in ((cfg.get("skills") or {}).get("external_dirs") or [])))
PY
)
if [[ -z $current ]]; then
  hermes config set skills.external_dirs "[\"$skills_dir\"]" >/dev/null
elif ! print -r -- "$current" | grep -qF "plugins/alice/skills"; then
  print -u2 "Add $skills_dir to skills.external_dirs in Hermes' config to see Alice's skills in the list."
fi

service=gui/$(id -u)/ai.hermes.dashboard
if launchctl print "$service" >/dev/null 2>&1; then
  launchctl kickstart -k "$service"
fi

print "Alice plugin installed. Open the Hermes dashboard → Alice tab for a pairing QR, or connect from Alice with the address and key."
