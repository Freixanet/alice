"""Place triggers: kept per profile, fired once per arrival, and waking the agent."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_places_test", Path(__file__).resolve().parents[1] / "places.py")
places = importlib.util.module_from_spec(spec)
spec.loader.exec_module(places)


class PlacesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)

    def test_a_trigger_waits_for_the_iphone_to_find_the_place(self):
        t = places.add(self.home, "Mercadona, Súria", "arrive", "Recuérdame el aceite")
        self.assertNotIn("lat", t)
        places.resolved(self.home, t["id"], 41.83, 1.75, "Mercadona · Súria")
        stored = places.read(self.home)[0]
        self.assertEqual((stored["lat"], stored["lon"], stored["label"]), (41.83, 1.75, "Mercadona · Súria"))

    def test_a_one_time_trigger_fires_once_and_is_gone(self):
        t = places.add(self.home, "Casa", "arrive", "Enciende la calefacción")
        self.assertIsNone(places.fired(self.home, t["id"], "leave", now=1000))
        self.assertEqual(places.fired(self.home, t["id"], "arrive", now=1000)["task"], "Enciende la calefacción")
        self.assertEqual(places.read(self.home), [])

    def test_a_repeating_trigger_ignores_jitter_at_the_edge(self):
        t = places.add(self.home, "Trabajo", "leave", "Avisa en casa", repeat=True)
        self.assertIsNotNone(places.fired(self.home, t["id"], "leave", now=1000))
        self.assertIsNone(places.fired(self.home, t["id"], "leave", now=1000 + 60))
        self.assertIsNotNone(places.fired(self.home, t["id"], "leave", now=1000 + places.REFIRE_AFTER + 1))

    def test_bad_requests_and_the_ios_limit(self):
        with self.assertRaises(places.PlaceError):
            places.add(self.home, "Casa", "sometime", "x")
        for i in range(places.MAX_TRIGGERS):
            places.add(self.home, f"Sitio {i}", "arrive", "x")
        with self.assertRaises(places.PlaceError):
            places.add(self.home, "Uno más", "arrive", "x")

    def test_waking_creates_a_one_off_routine_in_the_agents_chat(self):
        created = {}
        fake = mock.Mock(create_job=lambda prompt, schedule, **kw: created.update(prompt=prompt, **kw) or {"id": "j1"})
        with mock.patch.dict(sys.modules, {"cron.jobs": fake}):
            places.wake({"place": "Mercadona", "when": "arrive", "task": "Recuérdame el aceite"})
        self.assertEqual((created["repeat"], created["deliver"]), (1, "bot-chat"))
        self.assertIn("acaba de llegar a Mercadona", created["prompt"])
        self.assertIn("Recuérdame el aceite", created["prompt"])

    def test_the_tool(self):
        out = places.run_tool(self.home, {"action": "add", "place": "Súper", "when": "arrive", "task": "Aceite"})
        self.assertTrue(out["ok"])
        self.assertEqual(len(places.run_tool(self.home, {"action": "list"})["triggers"]), 1)
        self.assertTrue(places.run_tool(self.home, {"action": "remove", "id": out["trigger"]["id"]})["ok"])


if __name__ == "__main__":
    unittest.main()
