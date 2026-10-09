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

# The installed plugin is kept beside the new one until this install finishes, and comes back
# if it fails: a half-copied plugin left Hermes without its purchase gates.
backup=""
if [[ -d $dest ]]; then
  mkdir -p "$hermes_home/backups"
  backup=$hermes_home/backups/alice-plugin-$(date +%Y%m%d-%H%M%S)
  [[ -d $dest/skills ]] && chmod -R u+w "$dest/skills"
  cp -R "$dest" "$backup"
  print "Previous plugin kept at $backup"
fi
restore() {
  if [[ -n $backup && -d $backup ]]; then
    print -u2 "The install failed; the previous plugin is back in place."
    rm -rf "$dest" && cp -R "$backup" "$dest"
  fi
}
trap restore ERR
staging=$hermes_home/plugins/.alice-new
rm -rf "$staging"
mkdir -p "$staging"
cp -R "$here/." "$staging/"
rm -rf "$dest"
mv "$staging" "$dest"
# Which source this is: the plugin's version never changed (always 1.0.0), so nobody could tell.
git -C "$here" rev-parse --short HEAD > "$dest/INSTALLED_FROM" 2>/dev/null || print "unknown" > "$dest/INSTALLED_FROM"

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
import sys
try:
    import hermes_yaml as yaml
except ImportError:
    import yaml
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

# Initialize the one morning routine and reuse the existing no-agent watcher poller.
# This does not poll mail, dispatch notices or call any model.
PYTHONPATH="$hermes_home/hermes-agent${PYTHONPATH:+:$PYTHONPATH}" "$python" - "$dest" "$hermes_home" <<'PY'
import importlib.util, sys
from pathlib import Path
root, home = Path(sys.argv[1]), Path(sys.argv[2])
def load(name):
    spec = importlib.util.spec_from_file_location('alice_' + name, root / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module
store = load('watchers').Store(home)
try:
    load('proactive').Service(store)
    load('watcher_service').ensure_morning_schedule(home)
finally:
    store.close()
PY

# The gateway runs the agents and keeps the plugin's modules loaded: without a restart it goes on
# with the old code.
for name in ai.hermes.gateway ai.hermes.dashboard; do
  service=gui/$(id -u)/$name
  if launchctl print "$service" >/dev/null 2>&1; then
    launchctl kickstart -k "$service"
    port=9119
    [[ $name == ai.hermes.gateway ]] && port=8644
    "$python" - "$port" <<'PY'
import socket, sys, time
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    try:
        with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=1):
            break
    except OSError:
        time.sleep(0.5)
else:
    raise SystemExit('Hermes service did not open its port; stopping installation')
PY
  fi
done

print "Alice plugin installed. Open the Hermes dashboard → Alice tab for a pairing QR, or connect from Alice with the address and key."
