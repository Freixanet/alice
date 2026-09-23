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
cp -R "$here/." "$dest/"

# pypdf (BSD) for PDF forms, into the plugin's own folder: Hermes' environment is not touched.
python=$hermes_home/hermes-agent/venv/bin/python
[[ -x $python ]] || python=$(command -v python3)
if ! "$python" -m pip install --quiet --upgrade --target "$dest/vendor" 'pypdf==6.18.0'; then
  print -u2 "Could not install pypdf; PDF forms will ask for it until the plugin is installed again."
fi
hermes plugins enable alice --no-allow-tool-override

service=gui/$(id -u)/ai.hermes.dashboard
if launchctl print "$service" >/dev/null 2>&1; then
  launchctl kickstart -k "$service"
fi

print "Alice plugin installed. Open the Hermes dashboard → Alice tab for a pairing QR, or connect from Alice with the address and key."
