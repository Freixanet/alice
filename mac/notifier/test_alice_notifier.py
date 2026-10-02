import importlib.util
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('alice_notifier', Path(__file__).with_name('alice_notifier.py'))
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)


class Hermes:
    """A Hermes home with just the tables the watcher reads."""

    def __init__(self, root):
        self.root = Path(root)
        self.next_id = 1

    def profile(self, name, title=None):
        directory = self.root if name == 'default' else self.root / 'profiles' / name
        directory.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(directory / 'state.db')) as conn, conn:
            conn.execute('CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, source TEXT, title TEXT)')
            conn.execute('CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, '
                         'content TEXT, display_kind TEXT, finish_reason TEXT, timestamp REAL)')
            for source in ('tui', 'cron', 'api_server'):
                conn.execute('INSERT OR IGNORE INTO sessions VALUES (?, ?, NULL)', (source, source))
            conn.execute('INSERT OR IGNORE INTO sessions VALUES (?, ?, ?)', ('botchat', 'desktop', 'Bot Chat'))
        if title:
            (directory / 'profile.yaml').write_text('ui_meta:\n  hermes-bots:\n    title: %s\n' % title)
        return directory

    def row(self, name, source, content, display_kind=None, finish_reason='stop', age=0, role='assistant'):
        directory = self.root if name == 'default' else self.root / 'profiles' / name
        with closing(sqlite3.connect(directory / 'state.db')) as conn, conn:
            conn.execute('INSERT INTO messages (session_id, role, content, display_kind, finish_reason, timestamp) '
                         'VALUES (?, ?, ?, ?, ?, ?)', (source, role, content, display_kind, finish_reason, time.time() - age))

    def jobs(self, name, rows):
        directory = self.root if name == 'default' else self.root / 'profiles' / name
        (directory / 'cron').mkdir(parents=True, exist_ok=True)
        (directory / 'cron' / 'jobs.json').write_text(json.dumps({'jobs': rows}))


class NotifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.hermes = Hermes(self.temp.name)
        self.hermes.profile('default')
        self.hermes.profile('radar-ia', title='Radar IA')
        self.state = {}
        self.sent = []

    def tearDown(self):
        self.temp.cleanup()

    def poll(self, wait=0):
        return n.poll_once(
            self.state, self.hermes.root, lambda *m: self.sent.append(m),
            now=time.time() + wait,
        )

    def test_nothing_old_is_announced_when_watching_starts(self):
        self.hermes.row('radar-ia', 'tui', 'informe de ayer')
        self.poll()
        self.assertEqual(self.sent, [])

    def test_a_bot_reply_says_who_answered_not_what(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'contenido privado')
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(self.sent, [('Radar IA', 'Ha respondido', 'alice://open?bot=radar-ia')])
        self.assertNotIn('contenido privado', repr(self.sent))

    def test_alice_replies_open_the_conversation_they_belong_to(self):
        self.poll()
        self.hermes.row('default', 'api_server', 'hola')
        self.poll(wait=n.SETTLE_SECONDS)
        # The fake session's id is its source name; in Hermes it is Alice's conversation id.
        self.assertEqual(self.sent, [('Alice', 'Ha respondido', 'alice://open?chat=api_server')])

    def test_what_alice_writes_in_her_own_chat_opens_today(self):
        self.poll()
        self.hermes.row('default', 'botchat', 'buenos días')
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(self.sent, [('Alice', 'Ha respondido', 'alice://open?bot=default')])

    def test_a_routines_own_transcript_and_tool_steps_stay_quiet(self):
        self.poll()
        self.hermes.row('radar-ia', 'cron', 'borrador de la rutina')
        self.hermes.row('radar-ia', 'tui', '', finish_reason='tool_calls')
        self.hermes.row('radar-ia', 'tui', '[SILENT]')
        self.poll()
        self.assertEqual(self.sent, [])

    def test_a_routine_result_and_a_failure_are_told_apart(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'informe', display_kind='cron_delivery', finish_reason=None)
        self.poll(wait=n.SETTLE_SECONDS)
        self.hermes.row('radar-ia', 'tui', "⚠️ Cron 'Radar IA' failed: …", display_kind='cron_delivery', finish_reason=None)
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual([m[1] for m in self.sent], ['Ha terminado su rutina', 'Su rutina ha fallado'])

    def test_a_bots_answer_to_a_routine_report_is_the_routine_finishing(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', '[Cronjob "Radar IA" output — scheduled job, not the user. Review it.]\n\ninforme',
                        finish_reason=None, role='user')
        self.hermes.row('radar-ia', 'tui', '', finish_reason='tool_calls')
        self.hermes.row('radar-ia', 'tui', 'resumen')
        self.poll(wait=n.SETTLE_SECONDS)
        self.hermes.row('radar-ia', 'tui', 'hola', finish_reason=None, role='user')
        self.hermes.row('radar-ia', 'tui', 'respuesta')
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual([m[1] for m in self.sent], ['Ha terminado su rutina', 'Ha respondido'])

    def test_a_bots_answer_to_a_failed_routine_is_the_routine_failing(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', '[Cronjob "Radar IA" output — scheduled job, not the user. Review it.]\n\n'
                        "⚠️ Cron 'Radar IA' failed: provider rate limit.", finish_reason=None, role='user')
        self.hermes.row('radar-ia', 'tui', "⚠️ Cron 'Radar IA' failed: provider rate limit.")
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual([m[1] for m in self.sent], ['Su rutina ha fallado'])

    def test_a_burst_from_one_chat_is_one_notification(self):
        self.poll()
        for text in ('uno', 'dos', 'tres'):
            self.hermes.row('radar-ia', 'tui', text)
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(len(self.sent), 1)

    def test_rows_found_long_after_they_were_written_are_history(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'respuesta vieja', age=3600)
        self.poll()
        self.assertEqual(self.sent, [])

    def test_a_routine_delivering_elsewhere_is_mentioned_only_when_it_fails(self):
        self.hermes.jobs('default', [{'id': 'j1', 'name': 'aviso-bateria', 'deliver': 'origin', 'last_run_at': 't0', 'last_status': 'ok'}])
        self.poll()
        self.hermes.jobs('default', [{'id': 'j1', 'name': 'aviso-bateria', 'deliver': 'origin', 'last_run_at': 't1', 'last_status': 'ok'}])
        self.poll()
        self.assertEqual(self.sent, [])
        self.hermes.jobs('default', [{'id': 'j1', 'name': 'aviso-bateria', 'deliver': 'origin', 'last_run_at': 't2', 'last_status': 'error'}])
        self.poll()
        self.assertEqual(self.sent, [('Alice', 'La rutina «aviso-bateria» ha fallado', 'alice://open?chat=home')])

    def test_a_bot_chat_routine_failure_is_not_told_twice(self):
        self.hermes.jobs('radar-ia', [{'id': 'j2', 'name': 'informe', 'deliver': 'bot-chat', 'last_run_at': 't0', 'last_status': 'ok'}])
        self.poll()
        self.hermes.jobs('radar-ia', [{'id': 'j2', 'name': 'informe', 'deliver': 'bot-chat', 'last_run_at': 't1', 'last_status': 'error'}])
        self.hermes.row('radar-ia', 'tui', "⚠️ Cron 'informe' failed", display_kind='cron_delivery', finish_reason=None)
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(self.sent, [('Radar IA', 'Su rutina ha fallado', 'alice://open?bot=radar-ia')])

    def test_an_unreadable_profile_does_not_silence_the_others(self):
        broken = self.hermes.root / 'profiles' / 'broken'
        broken.mkdir(parents=True)
        (broken / 'state.db').write_bytes(b'not a database')
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'hola')
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(self.sent, [('Radar IA', 'Ha respondido', 'alice://open?bot=radar-ia')])

    def test_a_cleanly_closed_wal_database_is_still_read(self):
        # Hermes keeps state.db in WAL mode; once every writer closes, the -wal
        # and -shm files are gone and a read-only open used to fail every pass.
        db = self.hermes.root / 'profiles' / 'radar-ia' / 'state.db'
        with closing(sqlite3.connect(db)) as conn, conn:
            conn.execute('PRAGMA journal_mode=WAL')
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'hola')
        # macOS's own SQLite keeps an emptied -wal on close; the one Hermes runs on
        # does not. Leave the files as Hermes does: checkpointed, closed, side files gone.
        with closing(sqlite3.connect(db)) as conn:
            conn.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        for suffix in ('-wal', '-shm'):
            Path(str(db) + suffix).unlink(missing_ok=True)
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(self.sent, [('Radar IA', 'Ha respondido', 'alice://open?bot=radar-ia')])

    def test_the_database_is_only_read(self):
        self.poll()
        db = self.hermes.root / 'profiles' / 'radar-ia' / 'state.db'
        before = db.read_bytes()
        self.hermes.row('radar-ia', 'tui', 'hola')
        after_write = db.read_bytes()
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(db.read_bytes(), after_write)
        self.assertNotEqual(before, after_write)

    def test_a_stop_is_not_the_answer_if_the_turn_continues(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'voy a buscarlo')
        self.poll()
        self.assertEqual(self.sent, [])
        self.assertIn('radar-ia/tui', self.state.get('pending', {}))
        self.hermes.row('radar-ia', 'tui', '', finish_reason='tool_calls')
        self.hermes.row('radar-ia', 'tui', 'aquí está')
        self.poll()
        self.assertEqual(self.sent, [])
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(self.sent, [('Radar IA', 'Ha respondido', 'alice://open?bot=radar-ia')])
        self.assertNotIn('radar-ia/tui', self.state.get('pending', {}))

    def test_the_last_assistant_row_notifies_once_it_has_settled(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'respuesta')
        self.poll()
        self.assertEqual(self.sent, [])
        self.poll(wait=n.SETTLE_SECONDS)
        self.assertEqual(self.sent, [('Radar IA', 'Ha respondido', 'alice://open?bot=radar-ia')])

    def test_a_user_row_settles_the_assistant_above_it(self):
        self.poll()
        self.hermes.row('radar-ia', 'tui', 'primera')
        self.poll()
        self.assertEqual(self.sent, [])
        self.hermes.row('radar-ia', 'tui', 'sigue', role='user', finish_reason=None)
        self.poll()
        self.assertEqual(self.sent, [('Radar IA', 'Ha respondido', 'alice://open?bot=radar-ia')])



class ErrandNotifierTests(unittest.TestCase):
    """Errands (the Alice plugin's errands.py): what they ask of the person, never what they are."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.hermes = Hermes(self.temp.name)
        self.home = self.hermes.profile('default')
        self.state = {}
        self.sent = []

    def tearDown(self):
        self.temp.cleanup()

    def errands(self, *entries):
        (self.home / '.alice').mkdir(exist_ok=True)
        (self.home / '.alice' / 'errands.json').write_text(json.dumps(list(entries)))

    def poll(self):
        return n.poll_errands(self.state, self.hermes.root, lambda *m, **kw: self.sent.append((m, kw)))

    def test_an_errand_waiting_for_approval_rings_at_once_and_says_nothing_of_it(self):
        self.errands()
        self.poll()
        self.errands({'id': 'abc', 'title': 'Comprar Creapure en HSN', 'status': 'working', 'updated_at': time.time()})
        self.poll()
        self.assertEqual(self.sent, [])
        self.errands({'id': 'abc', 'title': 'Comprar Creapure en HSN', 'status': 'needs_approval',
                      'updated_at': time.time()})
        self.poll()
        self.assertEqual(self.sent, [(('Alice', 'Un recado necesita tu aprobación', 'alice://errand?id=abc'),
                                      {'level': 'timeSensitive'})])
        self.assertNotIn('Creapure', repr(self.sent))
        # The same state is not told twice.
        self.poll()
        self.assertEqual(len(self.sent), 1)

    def test_done_and_stuck_are_told_but_what_the_person_did_is_not(self):
        self.errands({'id': 'a', 'status': 'working'}, {'id': 'b', 'status': 'working'}, {'id': 'c', 'status': 'working'})
        self.poll()
        now = time.time()
        self.errands({'id': 'a', 'status': 'done', 'updated_at': now}, {'id': 'b', 'status': 'stuck', 'updated_at': now},
                     {'id': 'c', 'status': 'stopped', 'updated_at': now})
        self.poll()
        self.assertEqual([m[1] for m, _ in self.sent], ['Un recado ha terminado', 'Un recado se ha atascado'])

    def test_a_shop_login_and_an_unconfirmed_payment_ring_at_once(self):
        self.errands({'id': 'a', 'status': 'working'}, {'id': 'b', 'status': 'working'})
        self.poll()
        now = time.time()
        self.errands({'id': 'a', 'status': 'needs_login', 'updated_at': now},
                     {'id': 'b', 'status': 'stuck', 'updated_at': now, 'receipt': {'outcome': 'unknown'}})
        self.poll()
        self.assertEqual([(m[1], kw['level']) for m, kw in self.sent],
                         [('Un recado necesita que inicies sesión en la tienda', 'timeSensitive'),
                          ('Un recado se ha parado y no está confirmado si el pago se hizo', 'timeSensitive')])

    def test_nothing_is_announced_when_watching_starts(self):
        self.errands({'id': 'abc', 'status': 'needs_approval', 'updated_at': time.time()})
        self.poll()
        self.assertEqual(self.sent, [])

    def test_an_errands_own_replies_are_not_a_chat_reply(self):
        with closing(sqlite3.connect(self.home / 'state.db')) as conn, conn:
            conn.execute("INSERT INTO sessions VALUES ('errand-abc', 'api_server', NULL)")
        state, sent = {}, []
        n.poll_once(state, self.hermes.root, lambda *m: sent.append(m))
        self.hermes.row('default', 'errand-abc', 'checkout listo')
        n.poll_once(state, self.hermes.root, lambda *m: sent.append(m), now=time.time() + n.SETTLE_SECONDS)
        self.assertEqual(sent, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
