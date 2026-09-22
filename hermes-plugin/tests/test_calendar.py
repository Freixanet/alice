"""The calendar the iPhone sends, and what agents are told about it."""
import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class CalendarSnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cal = load(ROOT / "calendar_snapshot.py", "alice_calendar_snapshot_test")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def event(self, title, start, end, **extra):
        return {"title": title, "start": start, "end": end, **extra}

    def test_never_connected_says_so(self):
        self.assertEqual(self.cal.events(self.home)["status"], "not_connected")

    def test_connected_returns_only_the_window_asked_for(self):
        self.cal.save(self.home, [
            self.event("Dentista", "2026-09-24T09:00:00+02:00", "2026-09-24T10:00:00+02:00", location="Clínica"),
            self.event("Viaje", "2026-10-30T09:00:00+01:00", "2026-10-30T12:00:00+01:00"),
            self.event("Ayer", "2026-09-21T09:00:00+02:00", "2026-09-21T10:00:00+02:00"),
        ], "2026-09-21T00:00:00Z", "2026-11-01T00:00:00Z")
        now = datetime(2026, 9, 22, 8, 0, tzinfo=timezone.utc)
        found = self.cal.events(self.home, days_ahead=7, now=now)
        self.assertEqual(found["status"], "connected")
        self.assertEqual([e["title"] for e in found["events"]], ["Dentista"])
        self.assertEqual(found["events"][0]["location"], "Clínica")

    def test_notes_and_malformed_events_are_not_kept(self):
        self.cal.save(self.home, [
            self.event("Con notas", "2026-09-24T09:00:00Z", "2026-09-24T10:00:00Z", notes="privado"),
            {"title": "Sin horas"},
            self.event("Roto", "mañana", "pasado"),
        ], "a", "b")
        stored = json.loads((self.home / ".alice" / "calendar.json").read_text())
        self.assertEqual([e["title"] for e in stored["events"]], ["Con notas"])
        self.assertNotIn("notes", stored["events"][0])

    def test_not_now_is_remembered_until_he_connects(self):
        self.cal.decline(self.home)
        self.assertEqual(self.cal.events(self.home)["status"], "declined")
        self.cal.save(self.home, [], "a", "b")
        self.assertEqual(self.cal.events(self.home)["status"], "connected")

    def test_disconnecting_forgets_every_event(self):
        self.cal.save(self.home, [self.event("X", "2026-09-24T09:00:00Z", "2026-09-24T10:00:00Z")], "a", "b")
        self.cal.disconnect(self.home)
        self.assertEqual(self.cal.status(self.home), {"status": "not_connected"})
        self.assertNotIn("X", (self.home / ".alice" / "calendar.json").read_text())


class CalendarToolTests(unittest.TestCase):
    def test_the_tool_reads_the_installations_calendar_from_any_profile(self):
        plugin = load(ROOT / "__init__.py", "alice_plugin_calendar_test")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            profile = root / "profiles" / "chief-of-staff"
            profile.mkdir(parents=True)
            plugin._calendar().decline(root)
            fake = mock.MagicMock()
            fake.get_hermes_home = lambda: str(profile)
            with mock.patch.dict(sys.modules, {"hermes_constants": fake}):
                answer = json.loads(plugin.calendar_events_tool({}))
        self.assertEqual(answer["status"], "declined")

    def test_register_adds_the_calendar_tool(self):
        plugin = load(ROOT / "__init__.py", "alice_plugin_calendar_register_test")
        ctx = mock.Mock()
        plugin.register(ctx)
        names = [call.kwargs["name"] for call in ctx.register_tool.call_args_list]
        self.assertIn("calendar_events", names)


if __name__ == "__main__":
    unittest.main()
