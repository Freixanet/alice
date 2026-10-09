# Install Watchers and test one real Gmail watch

This is Phase 1 only. These steps install on the existing iPhone and Mac Hermes
host; they do not start Review Tasks. On 9 October, Codex installed and verified
build 88 and deployed the plugin with a backup. The test watcher was created
paused; real email/model/push checks await OAuth and cheap-route configuration.
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
# Both checks must succeed: the branch contains the installed source and is pushed.
alice_home="${HERMES_HOME:-$HOME/.hermes}"
alice_installed_source=$(cat "$alice_home/plugins/alice/INSTALLED_FROM")
git merge-base --is-ancestor "$alice_installed_source" HEAD
test "$(git rev-parse HEAD)" = "$(git rev-parse '@{upstream}')"
# A higher build number alone does NOT preserve another branch's features.
xcrun devicectl device info apps \
  --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  --bundle-id com.freixanet.alice --columns '*'
read 'alice_next_build?Enter an integer greater than the installed Alice build: '
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Alice.xcodeproj -scheme Alice -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/alice-watchers-device-build \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$alice_next_build" \
  ALICE_SOURCE_REVISION="$(git rev-parse --short HEAD)" build
```

Continue only after `BUILD SUCCEEDED`. The temporary build directory avoids Finder metadata added under Documents that
can block extension signing. This is a signed device build; the earlier
`CODE_SIGNING_ALLOWED=NO` verification product cannot be installed as-is.

```sh
xcrun devicectl device install app \
  --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  /private/tmp/alice-watchers-device-build/Build/Products/Debug-iphoneos/Alice.app
xcrun devicectl device info apps \
  --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B \
  --bundle-id com.freixanet.alice --columns '*'
```

Open Alice and confirm Settings → Version shows your new build and Revision.
Settings → Watchers appears when the dashboard is connected. If the device query
fails, reconnect/unlock the phone before proceeding; no install is established.

## 2. Update the existing plugin safely

The previous manual patch instructions were for the original Watchers-only
checkout. They are superseded by the recovered combined source. Do not reinstall
from the old `9dc0dcc`/`8a3fd02` code: it omits the previous native UI.

Before any plugin or iPhone installation, use a clean committed and pushed branch
that contains the commit in `~/.hermes/plugins/alice/INSTALLED_FROM`. Follow the
"one source, one agent at a time" section in **AGENTS.md**. Use the repository's
`hermes-plugin/install.sh` for a future plugin update, preserving its backup and
source receipt; restart gateway and verify it before restarting dashboard.

The live Watchers plugin was already updated with a backup on 9 October. The UI
recovery changes the iPhone app; it does not require another live plugin restart.
The watcher journal under `$alice_home/.alice/watchers` must remain in place.

## 3. Connect Gmail and configure the cheap classifier

### Verified Plus subscription route (9 October 2026)

The local owner's classifier is explicitly configured as `openai-codex`, model
`gpt-6-luna`, base URL `https://chatgpt.com/backend-api/codex`, with an empty
API-key-variable field. This provider uses Hermes' own existing ChatGPT OAuth
credentials and the Responses endpoint, with `reasoning.effort=none`,
`store=false`, and strict JSON-schema output. It never uses Hermes' auxiliary
model router. OAuth resolution is read-only: expired/unavailable credentials,
timeouts, stream errors, or a returned model different from the configured model
fail as `classifier_error`; they cannot trigger another model or origin.

Live requests rejected `gpt-5-nano` and `gpt-5-mini` with HTTP 400: not supported
with a ChatGPT account. `gpt-6-luna` accepted `none` despite the catalog advertising
only `low` and above. A strict-schema invoice classification completed with the
returned model `gpt-6-luna` and passed the full local decision validator.

The account usage endpoint reported plan `plus`, a 604800-second (weekly) window,
33% used, reset epoch `1791948661`; no secondary window, model-specific limit,
or RPM/TPM limit was returned. These values are a snapshot, not guaranteed limits.

The real dry run on `4ae19f9cce5546adb661d9634108528b` was attempted and stopped
at Gmail because `google_token.json` is absent. It made no classifier/main-model
call, no notification/ack, and no journal mutation. The watcher remains paused.
Complete Google consent before rerunning against real email; a synthetic schema
check is not evidence of a completed Gmail dry run.

After Google consent and enabling Gmail API, the empty real dry run succeeded
and the watcher was activated with no-agent cron `4dd22ecdff88`. The test email
was detected automatically, classified `notify` (0.98), acknowledged, and delivered
with receipt `b910875431144289ae423e697ddc48ff` settled without error. Hermes stored
the Spanish agent answer in the default profile's Bot Chat.

Alice's routine presentation previously displayed the Watchers internal prompt
and JSON while hiding that agent answer. The presentation now recognizes only
the named, typed Watchers handover, hides that internal request, and preserves
the agent answer. The original transcript remains intact; other routine cards
and ordinary user messages keep their existing behavior.

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

Everyday users create watchers by asking Alice in chat. The `watchers` tool must
receive an explicit `config.query` for Gmail and a non-empty script implementing
the requested alert rule. The tool schema exposes source settings to the model;
missing/blank queries and scripts are rejected at creation and activation.
There is no implicit `is:unread` fallback. If a company sender or the alert rule
is unclear, Alice should inspect connected Gmail sender metadata or ask the user
before creating, then inspect a dry run before activating. The Settings screen
manages existing watchers; it does not have a creation form.

The simplified native screen is named **Watches / Vigilancias**. It shows the
watch list and creation guidance first. Tap a watch for start/pause, test results
and pending-item recovery. Incomplete email watches say **Needs setup / Falta
configurar** and cannot be started. A separate **Notification setup /
Configuración de avisos** screen keeps model fields and alert preferences in
collapsed advanced sections. Source validation errors and test results use plain
language instead of HTTP errors, JSON or event IDs. Ignoring pending items still
requires confirmation and does not delete emails.

To remove a watch yourself, open **Watches → the watch → Delete watch** and
confirm its name. This stops polling, removes it from the list, revokes its
webhook and clears pending events and unsent alert batches. It does not delete
source emails or existing chat messages. A delivery already handed to Hermes
or in progress can still finish. An internal deletion marker prevents an
in-flight classifier or later retry from restoring the watch.

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

## Activation validation and starting point

A watch starts paused. Activation now runs its actual script in the sandbox on
one matching source item. A dry-only alert probe must execute `classify`,
`notify` and `ack`; a second dry run uses the explicitly configured cheap route
and must finish with an ack or notification. Neither run sends a message or
acks a real source item. No main-model fallback is permitted. Missing samples,
shadowed capabilities, classifier errors and incomplete processing refuse
activation; Settings → Watches retains the reason after reopening the screen.
A new source with no matching item needs a matching test item before activation.

The first live poll stores the newest item and observed IDs as its baseline. It
classifies and acknowledges none of that historical snapshot. Later Gmail polls
use `after:<epoch>` against Gmail's server arrival time, rather than the sender's
Date header. Ordered feeds stop at their first known item; a page without its
previous anchor is ignored rather than treating unproven historical IDs as new.
Changing a source filter requires deliberately resetting its baseline.

For the Barkibu repair, preserve watcher `5f9b8bde37f746fbb3d24dab0eeb6d70`,
set its query to `in:anywhere {from:barkibu barkibu}`, and capture a new baseline
before resuming. Historical journal entries remain intact; baseline items are
not acknowledged or replayed as notifications.
