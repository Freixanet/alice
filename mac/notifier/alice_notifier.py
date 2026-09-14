#!/usr/bin/env python3
"""Tells the phone when Alice or a bot answers, or a routine ends.

Alice cannot be woken while iOS has it suspended, and a push of its own needs a
paid Apple developer account. Until then this runs on the Mac that already hosts
Hermes and delivers through Bark (a free iOS app with its own push permission).
Tapping a notification opens Alice on that chat.

It reads each profile's Hermes database read-only and never changes it. A
notification says who answered, never what: a lock screen is a public surface.
The Bark key lives in the login Keychain and is never logged.

Python 3.9+, standard library only.
"""
import json
import logging
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERMES = Path(os.environ.get('HERMES_HOME') or Path.home() / '.hermes')
STATE = Path.home() / 'Library' / 'Application Support' / 'AliceNotifier' / 'state.json'
BARK_PUSH = 'https://api.day.app/push'
KEYCHAIN_SERVICE = 'alice-bark'
POLL_SECONDS = 5
# Chats a person is in. `cron` sessions are a routine's own working transcript;
# its result reaches the person as a delivery row in the bot's chat instead.
REPLY_SOURCES = {'tui', 'cli', 'desktop', 'api_server'}
# Replies older than this when first seen are history, not news: a watcher that
# was stopped for a day must not ring the phone for all of it.
FRESH_SECONDS = 15 * 60

log = logging.getLogger('alice-notifier')


def profiles(home):
    """(name, directory) for the default profile and every named one."""
    found = [('default', home)]
    root = home / 'profiles'
    if root.is_dir():
        found += sorted((p.name, p) for p in root.iterdir() if (p / 'state.db').is_file())
    return found


def display_name(name, directory):
    """The bot's title as Alice shows it; the default profile is Alice itself."""
    if name == 'default':
        return 'Alice'
    try:
        text = (directory / 'profile.yaml').read_text(encoding='utf-8')
    except OSError:
        return name
    match = re.search(r'hermes-bots:\s*\n\s+title:\s*(.+)', text)
    return match.group(1).strip().strip('\'"') if match else name


def classify(content, display_kind, finish_reason, source):
    """'reply', 'routine', 'routine_failed', or None for rows a person need not hear about."""
    text = (content or '').strip()
    if display_kind == 'cron_delivery':
        return 'routine_failed' if text.startswith('⚠️') else 'routine'
    if display_kind:
        return None
    if finish_reason == 'stop' and source in REPLY_SOURCES and text and text != '[SILENT]':
        return 'reply'
    return None


def assistant_rows(db, after_id):
    """Assistant rows newer than after_id, read-only."""
    uri = 'file:' + urllib.parse.quote(str(db)) + '?mode=ro'
    with sqlite3.connect(uri, uri=True, timeout=5) as conn:
        return conn.execute(
            'SELECT m.id, m.content, m.display_kind, m.finish_reason, s.source, m.timestamp, s.id '
            'FROM messages m JOIN sessions s ON s.id = m.session_id '
            'WHERE m.id > ? AND m.role = ? ORDER BY m.id', (after_id, 'assistant')).fetchall()


def last_message_id(db):
    uri = 'file:' + urllib.parse.quote(str(db)) + '?mode=ro'
    with sqlite3.connect(uri, uri=True, timeout=5) as conn:
        return conn.execute('SELECT COALESCE(MAX(id), 0) FROM messages').fetchone()[0]


def jobs(directory):
    path = directory / 'cron' / 'jobs.json'
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return []
    rows = data.get('jobs', data) if isinstance(data, dict) else data
    return list(rows.values()) if isinstance(rows, dict) else list(rows or [])


def link(name, chat=None):
    """Alice's own chats are stored in Hermes under the id Alice gave them."""
    query = {'chat': chat or 'home'} if name == 'default' else {'bot': name}
    return 'alice://open?' + urllib.parse.urlencode(query)


SENTENCES = {
    'reply': 'Ha respondido',
    'routine': 'Ha terminado su rutina',
    'routine_failed': 'Su rutina ha fallado',
}


def poll_once(state, home, send, now=None):
    """One pass over every profile. Returns the notifications sent, as (title, body, url)."""
    now = time.time() if now is None else now
    marks = state.setdefault('messages', {})
    runs = state.setdefault('runs', {})
    sent = []
    for name, directory in profiles(home):
        title = display_name(name, directory)
        db = directory / 'state.db'
        if db.is_file():
            if name not in marks:
                # First sight of this profile: start from now, announce nothing old.
                marks[name] = last_message_id(db)
            else:
                rows = assistant_rows(db, marks[name])
                found = []
                for row_id, content, display_kind, finish_reason, source, stamp, session in rows:
                    kind = classify(content, display_kind, finish_reason, source)
                    if kind and (stamp is None or now - float(stamp) <= FRESH_SECONDS):
                        found.append((kind, session if source == 'api_server' else None))
                # A burst from one chat is one notification; a failure outranks the rest.
                for kind in ('routine_failed', 'routine', 'reply'):
                    match = next((f for f in reversed(found) if f[0] == kind), None)
                    if match:
                        message = (title, SENTENCES[kind], link(name, match[1]))
                        send(*message)
                        sent.append(message)
                        break
                if rows:
                    marks[name] = rows[-1][0]
        # Routines that deliver somewhere other than a bot's chat leave no row to
        # watch. Their successes already reach wherever they deliver; say only
        # when one fails.
        for job in jobs(directory):
            key = '%s/%s' % (name, job.get('id'))
            ran = job.get('last_run_at')
            if key not in runs:
                runs[key] = ran
                continue
            if ran and ran != runs[key]:
                runs[key] = ran
                if job.get('deliver') != 'bot-chat' and job.get('last_status') not in (None, 'ok'):
                    message = (title, 'La rutina «%s» ha fallado' % job.get('name', ''), link(name))
                    send(*message)
                    sent.append(message)
    return sent


def keychain_key():
    try:
        out = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', KEYCHAIN_SERVICE, '-w'],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None if out.returncode == 0 else None


def bark_sender(key):
    def send(title, body, url):
        payload = json.dumps({'device_key': key, 'title': title, 'body': body, 'url': url,
                              'group': title, 'level': 'active'}).encode()
        request = urllib.request.Request(BARK_PUSH, data=payload, method='POST',
                                         headers={'Content-Type': 'application/json; charset=utf-8'})
        with urllib.request.urlopen(request, timeout=10) as response:
            if response.status != 200:
                raise RuntimeError('Bark answered %d' % response.status)
    return send


def load_state(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(state), encoding='utf-8')
    os.replace(temp, path)


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    state = load_state(STATE)
    warned = False
    while True:
        key = keychain_key()
        if key is None and not warned:
            log.warning('No Bark key in the Keychain (service %s); watching without sending.', KEYCHAIN_SERVICE)
            warned = True
        if key is not None:
            warned = False

        def send(title, body, url):
            if key is None:
                return
            try:
                bark_sender(key)(title, body, url)
                log.info('Notified: %s — %s', title, body)
            except Exception as error:  # a failed push must not stop the watcher
                log.warning('Could not notify %s: %s', title, type(error).__name__)

        try:
            poll_once(state, HERMES, send)
            save_state(STATE, state)
        except Exception as error:
            log.warning('Pass failed: %s', type(error).__name__)
        time.sleep(POLL_SECONDS)


if __name__ == '__main__':
    sys.exit(main())
