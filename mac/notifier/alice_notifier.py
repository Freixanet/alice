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
# How stock Hermes opens a routine's report when it hands it to a bot's chat
# (cron/scheduler_delivery.py); the bot's answer to it is the routine finishing.
ROUTINE_REPORT = '[Cronjob "'
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


def classify(content, display_kind, finish_reason, source, answers_routine=False):
    """'reply', 'routine', 'routine_failed', or None for rows a person need not hear about.

    answers_routine: the turn this row answers is a routine's report, which stock Hermes
    hands to the bot's chat as a message starting with ROUTINE_REPORT."""
    text = (content or '').strip()
    if display_kind == 'cron_delivery':
        return 'routine_failed' if text.startswith('⚠️') else 'routine'
    if display_kind:
        return None
    if finish_reason == 'stop' and source in REPLY_SOURCES and text and text != '[SILENT]':
        return 'routine' if answers_routine else 'reply'
    return None


def read(db, sql, args=()):
    """Rows from a Hermes database, opened read-only and closed straight after.

    `with sqlite3.connect(...)` only ends a transaction and leaves the
    connection open, which a watcher polling seven databases every few seconds
    cannot afford."""
    try:
        return _query(db, sql, args, immutable=False)
    except sqlite3.OperationalError:
        # A WAL database closed cleanly has no -wal or -shm file, and a read-only
        # connection cannot create the -shm it needs ("unable to open database
        # file"). With no -wal there is nothing unmerged, so the file as it
        # stands is exactly the database.
        if Path(str(db) + '-wal').exists():
            raise
        return _query(db, sql, args, immutable=True)


def _query(db, sql, args, immutable):
    uri = 'file:' + urllib.parse.quote(str(db)) + '?mode=ro' + ('&immutable=1' if immutable else '')
    conn = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        return conn.execute(sql, args).fetchall()
    finally:
        conn.close()


def assistant_rows(db, after_id):
    """Assistant rows newer than after_id, or None when the database cannot be read."""
    try:
        # Whether the user turn before each row is a routine's report, decided in SQL so
        # the report itself never leaves the database.
        return read(db,
                    'SELECT m.id, m.content, m.display_kind, m.finish_reason, s.source, m.timestamp, s.id, '
                    '(SELECT substr(u.content, 1, ?) = ? FROM messages u WHERE u.session_id = m.session_id '
                    'AND u.id < m.id AND u.role = ? ORDER BY u.id DESC LIMIT 1) '
                    'FROM messages m JOIN sessions s ON s.id = m.session_id '
                    'WHERE m.id > ? AND m.role = ? ORDER BY m.id',
                    (len(ROUTINE_REPORT), ROUTINE_REPORT, 'user', after_id, 'assistant'))
    except sqlite3.Error as error:
        # One unreadable database must not silence every other chat.
        log.warning('Could not read %s: %s', db.parent.name, error)
        return None


def last_message_id(db):
    try:
        return read(db, 'SELECT COALESCE(MAX(id), 0) FROM messages')[0][0]
    except sqlite3.Error as error:
        log.warning('Could not read %s: %s', db.parent.name, error)
        return None


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
                last = last_message_id(db)
                if last is not None:
                    marks[name] = last
            else:
                rows = assistant_rows(db, marks[name]) or []
                found = []
                for row_id, content, display_kind, finish_reason, source, stamp, session, after_report in rows:
                    kind = classify(content, display_kind, finish_reason, source, bool(after_report))
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
            # Database, file and JSON errors name the problem, never chat content.
            log.warning('Pass failed: %s: %s', type(error).__name__, error)
        time.sleep(POLL_SECONDS)


if __name__ == '__main__':
    sys.exit(main())
