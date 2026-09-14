#!/bin/zsh
# Installs the Alice notifier as a login agent on the Mac that hosts Hermes.
#
# The Bark key is not handled here. Store it yourself, once, in the login
# Keychain (the prompt hides what you type):
#
#   security add-generic-password -U -s alice-bark -a "$USER" -T /usr/bin/security -w
#
# Uninstall: launchctl bootout gui/$(id -u)/com.freixanet.alice.notifier
set -euo pipefail

here=${0:A:h}
dest="$HOME/Library/Application Support/AliceNotifier"
plist="$HOME/Library/LaunchAgents/com.freixanet.alice.notifier.plist"
label=com.freixanet.alice.notifier

mkdir -p "$dest" "$HOME/Library/Logs"
cp "$here/alice_notifier.py" "$dest/alice_notifier.py"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$dest/alice_notifier.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PYTHONDONTWRITEBYTECODE</key><string>1</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/AliceNotifier.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/AliceNotifier.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Alice notifier installed and running."
