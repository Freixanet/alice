"""Los hechos del «Buenos días» y el instalador, contra un Hermes de mentira."""
import importlib.util
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dias = load("buenos_dias")
instalar = load("instalar")
cita = load("antes_de_cita")
cierre = load("cierre_dia")


class Hermes:
    def __init__(self, root: Path):
        self.root = root
        (root / "config.yaml").write_text("timezone: Europe/Madrid\n")

    def agent(self, name, title=None, internal=False):
        directory = self.root / "profiles" / name
        directory.mkdir(parents=True)
        meta = "ui_meta:\n"
        if title:
            meta += f"  hermes-bots:\n    title: {title}\n"
        if internal:
            meta += "  alice:\n    internal: true\n"
        (directory / "profile.yaml").write_text(meta)
        with closing(sqlite3.connect(directory / "state.db")) as conn, conn:
            conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT)")
            conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, "
                         "content TEXT, timestamp REAL)")
            conn.execute("INSERT INTO sessions VALUES ('bc', 'Bot Chat'), ('other', 'Otra cosa')")
        return directory

    def say(self, name, role, content, age=60, session="bc"):
        with closing(sqlite3.connect(self.root / "profiles" / name / "state.db")) as conn, conn:
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
                         (session, role, content, time.time() - age))


class FactsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.hermes = Hermes(Path(self.temp.name))

    def tearDown(self):
        self.temp.cleanup()

    def test_what_each_agent_said_overnight_with_its_latest_opening(self):
        self.hermes.agent("radar-ia", title="Radar IA")
        self.hermes.say("radar-ia", "user", '[Cronjob "Radar" output — scheduled job, not the user.]\n\ninforme')
        self.hermes.say("radar-ia", "assistant", "## Tres novedades\n**OpenAI** lanza algo")
        text = dias.facts(self.hermes.root, time.time(), 16)
        self.assertIn("- Radar IA: 1 informe(s) de rutina, 1 respuesta(s)", text)
        self.assertIn("«Tres novedades OpenAI lanza algo»", text)

    def test_old_chats_silence_and_other_sessions_are_left_out(self):
        self.hermes.agent("radar-ia", title="Radar IA")
        self.hermes.say("radar-ia", "assistant", "de hace dos días", age=2 * 86400)
        self.hermes.say("radar-ia", "assistant", "[SILENT]")
        self.hermes.say("radar-ia", "assistant", "en otro chat", session="other")
        text = dias.facts(self.hermes.root, time.time(), 16)
        self.assertIn("- Nada nuevo.", text)

    def test_an_internal_profile_is_not_news(self):
        self.hermes.agent("evals-sandbox", internal=True)
        self.hermes.say("evals-sandbox", "assistant", "prueba")
        self.assertIn("- Nada nuevo.", dias.facts(self.hermes.root, time.time(), 16))

    def test_the_date_is_in_hermes_timezone_and_in_spanish(self):
        # 2026-09-22 00:30 UTC is still Monday in New York but Tuesday in Madrid.
        text = dias.facts(self.hermes.root, 1790037000, 16)
        self.assertTrue(text.startswith("Fecha: martes 22 de septiembre, 02:30"), text)


    def test_todays_calendar_is_in_the_facts_only_when_connected(self):
        import json
        now = 1790060400  # 2026-09-22 09:00 in Madrid
        self.assertNotIn("agenda", dias.facts(self.hermes.root, now, 16))
        (self.hermes.root / ".alice").mkdir()
        (self.hermes.root / ".alice" / "calendar.json").write_text(json.dumps({
            "connected": True,
            "events": [
                {"title": "Dentista", "start": "2026-09-22T17:00:00+02:00",
                 "end": "2026-09-22T18:00:00+02:00", "location": "Clínica"},
                {"title": "Mañana", "start": "2026-09-23T10:00:00+02:00",
                 "end": "2026-09-23T11:00:00+02:00"},
            ],
        }))
        text = dias.facts(self.hermes.root, now, 16)
        self.assertIn("- 17:00 Dentista · Clínica", text)
        self.assertNotIn("Mañana", text)


class AppointmentTests(unittest.TestCase):
    NOW = 1790060400  # 2026-09-22 09:00 in Madrid

    def setUp(self):
        import json
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        (self.home / "config.yaml").write_text("timezone: Europe/Madrid\n")
        (self.home / ".alice").mkdir()
        (self.home / ".alice" / "calendar.json").write_text(json.dumps({"connected": True, "events": [
            {"title": "Dentista", "start": "2026-09-22T10:00:00+02:00", "end": "2026-09-22T11:00:00+02:00",
             "location": "Clínica"},
            {"title": "Demasiado pronto", "start": "2026-09-22T09:20:00+02:00", "end": "2026-09-22T09:40:00+02:00"},
            {"title": "Festivo", "start": "2026-09-22T00:00:00+02:00", "end": "2026-09-23T00:00:00+02:00",
             "all_day": True},
            {"title": "Mañana", "start": "2026-09-23T12:00:00+02:00", "end": "2026-09-23T13:00:00+02:00"},
        ]}))

    def tearDown(self):
        self.temp.cleanup()

    def test_only_what_starts_in_about_an_hour_and_the_line_does_not_move(self):
        first = cita.upcoming(self.home, self.NOW)
        self.assertEqual(first, ["- 10:00 Dentista · Clínica"])
        # A quarter of an hour later the same appointment reads the same, so
        # the monitor does not wake the model twice for it.
        self.assertEqual(cita.upcoming(self.home, self.NOW + 900), first)

    def test_nothing_when_the_calendar_is_not_connected(self):
        (self.home / ".alice" / "calendar.json").write_text('{"connected": false}')
        self.assertEqual(cita.upcoming(self.home, self.NOW), [])

    def test_the_evening_facts_hold_tomorrows_agenda(self):
        text = cierre.facts(self.home, self.NOW)
        self.assertIn("Su agenda de mañana:\n- 12:00 Mañana", text)
        self.assertNotIn("Dentista", text.split("Su agenda de mañana:")[1])


class EveningTests(unittest.TestCase):
    def test_what_he_wrote_today_once_and_nothing_a_routine_wrote(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / "config.yaml").write_text("timezone: Europe/Madrid\n")
            with closing(sqlite3.connect(home / "state.db")) as conn, conn:
                conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, title TEXT)")
                conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, "
                             "content TEXT, timestamp REAL)")
                conn.execute("INSERT INTO sessions VALUES ('a', 'api_server', 'Chat'), ('c', 'cron', 'x')")
                now = time.time()
                for session, text in (("a", "Le mando el presupuesto a Laura mañana"),
                                      ("a", "Le mando el presupuesto a Laura mañana"),
                                      ("a", '[Cronjob "Radar" output — scheduled job, not the user.]'),
                                      ("c", "borrador de una rutina")):
                    conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)",
                                 (session, text, now - 60))
            lines = cierre.said_today(home, time.time(), cierre.zone(home))
        self.assertEqual(lines, ["- Le mando el presupuesto a Laura mañana"])


class InstallerTests(unittest.TestCase):
    def test_the_block_is_added_once_and_then_replaced(self):
        first = instalar.with_block("# Alice\n", "<!-- alice:proactiva inicio -->\nA\n<!-- alice:proactiva fin -->")
        second = instalar.with_block(first, "<!-- alice:proactiva inicio -->\nB\n<!-- alice:proactiva fin -->")
        self.assertEqual(second.count("alice:proactiva inicio"), 1)
        self.assertIn("\nB\n", second)
        self.assertNotIn("\nA\n", second)

    def test_a_time_becomes_a_daily_schedule(self):
        self.assertEqual(instalar.schedule("07:30"), "30 7 * * *")
        with self.assertRaises(SystemExit):
            instalar.schedule("25:00")


if __name__ == "__main__":
    unittest.main()
