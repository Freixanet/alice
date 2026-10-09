# Install Watchers and test one real Gmail watch

This is Phase 1 only. These steps install on the existing iPhone and Mac Hermes
host; they do not start Review Tasks. The device build has compiled, but this
installation and a real email/model/push test have not been performed by Codex.
Run the commands in **zsh**. Keep the existing app; do not delete it.

## 1. Install on iPhone

Connect and unlock your iPhone, trust this Mac and enable Developer Mode if iOS
asks. On the phone, open Alice → Settings → Version and note the number in
parentheses. It must increase for this installation.

```sh
cd /Users/mfreixanet/Documents/ChatGPT/Alice
git status --short
# Expected: clean; branch codex/proactive-watchers.
git branch --show-current
xcrun devicectl device info apps \
  --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  --bundle-id com.freixanet.alice --columns '*'
read 'alice_next_build?Enter an integer greater than the installed Alice build: '
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$alice_next_build" \
  ALICE_SOURCE_REVISION="$(git rev-parse --short HEAD)" build
```

Continue only after `BUILD SUCCEEDED`. This is a signed device build; the earlier
`CODE_SIGNING_ALLOWED=NO` verification product cannot be installed as-is.

```sh
xcrun devicectl device install app \
  --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  ios/.build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
xcrun devicectl device info apps \
  --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  --bundle-id com.freixanet.alice --columns '*'
```

Open Alice and confirm Settings → Version shows your new build and Revision.
Settings → Watchers appears when the dashboard is connected. If the device query
fails, reconnect/unlock the phone before proceeding; no install is established.

## 2. Update the existing plugin safely

These commands update an **already installed** Alice plugin. They back it up and
apply a checked patch instead of overwriting unrelated live modifications. If the
check fails, stop and reconcile that conflict; do not force the patch. Pause any
existing watchers before updating an installation that already has this feature.

```sh
cd /Users/mfreixanet/Documents/ChatGPT/Alice
alice_home="${HERMES_HOME:-$HOME/.hermes}"
alice_backup="$alice_home/backups/plugin-alice-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$alice_home/backups"
cp -R "$alice_home/plugins/alice" "$alice_backup"
git diff --binary 684c4da HEAD -- hermes-plugin \
  ':!hermes-plugin/tests' ':!hermes-plugin/README.md' ':!hermes-plugin/__init__.py' \
  > /private/tmp/alice-watchers-plugin.patch
# Compose the registration hunk against the live file, preserving its extra hooks.
ALICE_WATCHER_PLUGIN_HOME="$alice_home" python3 - <<'PYINSTALL'
import difflib, os
from pathlib import Path
repo = Path('/Users/mfreixanet/Documents/ChatGPT/Alice')
live = Path(os.environ['ALICE_WATCHER_PLUGIN_HOME'])/'plugins/alice/__init__.py'
old = live.read_text()
anchor = '    _register_work_tools(ctx)\n'
marker = '    watcher_tools = _module("watcher_tools.py", "alice_watcher_tools")'
assert old.count(anchor) == 1, 'Ambiguous live registration: stop and reconcile.'
assert marker not in old, 'Watchers already registered: stop; do not install twice.'
source = (repo/'hermes-plugin/__init__.py').read_text()
block = source[source.index(marker):]
assert len(block) < 1000, 'Registration layout changed: stop and reconcile.'
new = old.replace(anchor, anchor + block)
patch = ''.join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
    fromfile='a/hermes-plugin/__init__.py', tofile='b/hermes-plugin/__init__.py'))
with Path('/private/tmp/alice-watchers-plugin.patch').open('a') as handle:
    handle.write(patch)
PYINSTALL
git apply --check --unsafe-paths -p2 \
  --directory="$alice_home/plugins/alice" /private/tmp/alice-watchers-plugin.patch
# Run the next command only if the check returned successfully.
git apply --unsafe-paths -p2 \
  --directory="$alice_home/plugins/alice" /private/tmp/alice-watchers-plugin.patch
hermes plugins enable alice --no-allow-tool-override
launchctl kickstart -k "gui/$(id -u)/ai.hermes.gateway"
hermes gateway status --deep
```

Wait for the gateway status to report healthy before restarting the dashboard:

```sh
launchctl kickstart -k "gui/$(id -u)/ai.hermes.dashboard"
```

Reconnect Alice. Open the existing main Alice chat. Watchers deliver into that
installation's main chat, not an arbitrary bot. No source data or keys go to a
shared Alice backend. To roll back, restore the backup and restart gateway then
dashboard in this same order. The watcher journal is kept separately under
`$alice_home/.alice/watchers`; do not delete it during rollback.

## 3. Connect Gmail and configure the cheap classifier

Use the dependency interpreter selected by Hermes' own package manager, rather
than assuming its old `hermes-agent/venv` is the running environment:

```sh
alice_python=$(PYTHONPATH="$alice_home/hermes-agent" \
  "$alice_home/hermes-agent/venv/bin/python" -c \
  'import os; from pathlib import Path; from pm.environments import project_python; home=Path(os.environ.get("HERMES_HOME", str(Path.home()/".hermes"))); print(project_python(home/"hermes-agent"))')
test -x "$alice_python"
alice_google="$alice_home/hermes-agent/skills/productivity/google-workspace/scripts"
PYTHONPATH="$alice_home/hermes-agent" "$alice_python" "$alice_google/setup.py" --check
```

If Gmail is not authenticated, use Hermes' existing Google Workspace setup. The
installed setup script supports the following commands (its current version
requests Workspace scopes, including Gmail send/modify; review Google's consent):

```sh
# First obtain your own Desktop OAuth client JSON via Google's setup UI.
PYTHONPATH="$alice_home/hermes-agent" "$alice_python" "$alice_google/setup.py" \
  --client-secret "$HOME/Downloads/YOUR_GOOGLE_CLIENT_SECRET.json"
PYTHONPATH="$alice_home/hermes-agent" "$alice_python" "$alice_google/setup.py" --auth-url
# Open the printed URL, authorize, and copy the complete localhost redirect URL.
# It may show a localhost connection error; the URL still contains the OAuth code.
read -rs 'alice_oauth_redirect?Paste the OAuth redirect URL (hidden): '
print
PYTHONPATH="$alice_home/hermes-agent" "$alice_python" "$alice_google/setup.py" \
  --auth-code "$alice_oauth_redirect"
unset alice_oauth_redirect
PYTHONPATH="$alice_home/hermes-agent" "$alice_python" "$alice_google/setup.py" --check
```

If the setup reports missing Google dependencies, use its own `--install-deps`
option with this interpreter, then restart Hermes gateway/dashboard in the order
above and retry `--check`. Do not install unrelated packages into its runtime.
Do not continue until authentication succeeds. In Alice → Settings → Watchers,
enter your deliberately selected cheap provider/model, its compatible API base
URL (including `/v1` if that endpoint requires it), and the name of its existing
key variable in the host environment or `$alice_home/.env`. Do not put the key
in chat or in the phone's variable-name field. The endpoint must support strict
JSON-schema structured output. Save classifier. This feature does not select a
model or buy access for you; those account-specific values cannot be invented.

## 4. Create one paused Gmail watcher, dry run, then activate

This host command creates exactly one watcher, without invoking the main model.
Its query is restricted to a unique test subject. Keep the printed ID for retry
or pause. Run this creation once; repeating it creates another watcher.

```sh
alice_watcher_id=$(PYTHONPATH="$alice_home/hermes-agent" "$alice_python" - <<'PY'
import os, sys
from pathlib import Path
home = Path(os.environ.get('HERMES_HOME', str(Path.home()/'.hermes')))
sys.path.insert(0, str(home/'plugins/alice'))
from watchers import Store
code = '''
questions = {"action": {"type": "choice", "options": {
    "notify": "The body says invoice overdue and requests action today; notify the person",
    "quiet": "The body says invoice paid or nothing requires action; stay quiet",
    "defer": "Unclear; do not notify yet"}}}
answer = classify({"event": event}, questions)["action"]
if answer["key"] == "quiet":
    ack(event["id"])
elif answer["key"] == "notify" and answer["confidence"] >= 0.8:
    notify(event["body"], event["id"])
    ack(event["id"])
'''
store = Store(home)
try:
    row = store.create('local', 'Gmail test — overdue invoice', 'email',
        {'query': 'in:inbox subject:ALICE-WATCHER-TEST-20261009 newer_than:1d', 'every_minutes': 1},
        code, 'User requested one real test email watcher; alert for overdue invoice requiring action today.')
    print(row['id'])
finally:
    store.close()
PY
)
print -r -- "$alice_watcher_id"
```

In Settings → Watchers, refresh. You should see **Gmail test — overdue invoice**,
**paused**, with **0 pending**. Tap **Dry run**. With no matching mail it should
show no events and send no messages. Then tap **Activate**. Expect **active**.
If setup, sandbox or cron fails, resolve that visible error first.

## 5. Send a test email and observe the result

From another email account, manually send to the connected Gmail inbox:

- Subject: `ALICE-WATCHER-TEST-20261009`
- Plain text body: `invoice overdue. Please remind me to review this invoice today. This is a test; do not send, pay, or change anything.`

Ensure it is in Inbox, not Spam. Keep Hermes running and Alice open for the first
test. Within roughly 2–4 minutes, plus model latency, expect:

1. The host reads the full body, and the **cheap model** returns a decision.
2. A confident notify is durably queued; **pending returns to 0**.
3. After the one-minute batching window and Hermes dispatch, **one new message
   in the main Alice chat**, explaining the invoice and suggesting a next step.
4. Repeated polling of that same email does not create another message.

This depends on the live cheap model actually returning notify with confidence
≥ 0.8; it is not a hardcoded alert. If it returns quiet, no message is correct.
If it returns defer, the event stays pending. A classifier error gets two attempts
on the same cheap route, no ack/notify/main-model call, and is retained for retry.
After 15 minutes without ack the watcher fails and displays a notice.

For diagnosis without replaying the main model, tap **Dry run** to inspect the
recorded decision (it calls the cheap route again). Resolve the route/source issue
and tap **Retry pending**. Do not create another watcher to retry the same event.
To check quiet behavior, send a new email with the same subject and body
`invoice paid. Everything is settled; no action is needed.` Expect no new chat
message and pending 0 after a quiet decision. Pause the test watcher when done.

## Push option and closed-app behavior

**Implemented option: the existing mechanism, Mac notifier → Bark.** Phase 1
extends it with generic watcher failure notices. Normal proactive replies use
the notifier's existing main-chat reply path. Bark gets a generic alert and deep
link, never the email body/classifier payload. The message is read from Hermes
when Alice opens. There is no new content-free relay or APNs server in this change.

For alerts while Alice is closed, configure your existing Bark app/notification
permission and install the updated notifier on the Hermes Mac:

```sh
# Enter the Bark device key in the hidden Keychain prompt; never paste it in chat.
security add-generic-password -U -s alice-bark -a "$USER" -T /usr/bin/security -w
cd /Users/mfreixanet/Documents/ChatGPT/Alice
zsh mac/notifier/install.sh
```

Start it **before** sending the test email: historical replies are not pushed.
Expect a generic Bark notification after the chat reply settles; tapping it opens
Alice. Allow notifications for Bark in iOS Settings. Without Bark, the existing
Alice local notifications can catch up only when iOS runs the app/background
refresh; they do not guarantee prompt delivery when suspended or force-quit.
A dedicated Alice APNs/content-free relay remains a possible future step, not
something implemented or required for this existing-mechanism option.
