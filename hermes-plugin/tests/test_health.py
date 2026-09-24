"""Health read carefully: quiet unless clearly off, patterns only with enough days."""
import importlib.util
import random
import sys
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_health_test", Path(__file__).resolve().parents[1] / "health.py")
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)

TODAY = date(2026, 9, 25)


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def days(self, n, make):
        rows = []
        for i in range(n, 0, -1):
            d = TODAY - timedelta(days=i - 1)
            rows.append({"date": d.isoformat(), **make(i, d)})
        health.save(self.root, rows)

    def test_a_normal_night_says_nothing(self):
        rnd = random.Random(1)
        self.days(30, lambda i, d: {"sleep_h": 7.2 + rnd.uniform(-0.3, 0.3), "hrv": 60 + rnd.uniform(-4, 4)})
        self.assertEqual(health.notable(self.root, TODAY), [])

    def test_a_short_night_and_low_hrv_are_named(self):
        rnd = random.Random(2)
        self.days(30, lambda i, d: {"sleep_h": 7.3 + rnd.uniform(-0.3, 0.3), "hrv": 62 + rnd.uniform(-3, 3)})
        health.save(self.root, [{"date": TODAY.isoformat(), "sleep_h": 5.4, "hrv": 44}])
        lines = health.notable(self.root, TODAY)
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith("- sueño anoche: 5 h 24 min"))
        self.assertIn("variabilidad del pulso", lines[1])

    def test_a_good_night_is_not_news(self):
        rnd = random.Random(3)
        self.days(30, lambda i, d: {"sleep_h": 6.8 + rnd.uniform(-0.2, 0.2)})
        health.save(self.root, [{"date": TODAY.isoformat(), "sleep_h": 9.0}])
        self.assertEqual(health.notable(self.root, TODAY), [])

    def test_patterns_need_enough_days_and_a_real_relation(self):
        rnd = random.Random(4)
        work = {}
        def make(i, d):
            w = rnd.choice([0, 0, 30, 60, 90])
            work[d] = w
            prev = work.get(d - timedelta(days=1), 0)
            return {"workout_min": w, "sleep_h": 7.8 - prev / 100 + rnd.uniform(-0.1, 0.1)}
        self.days(10, make)
        self.assertEqual(health.patterns(self.root, today=TODAY), [])  # too few days
        self.days(40, make)
        found = health.patterns(self.root, today=TODAY)
        self.assertEqual((found[0]["cause"], found[0]["effect"], found[0]["lag"]), ("workout_min", "sleep_h", 1))
        self.assertLess(found[0]["r"], -0.4)
        self.assertIn("esa noche", found[0]["text"])

    def test_before_after_and_week(self):
        self.days(40, lambda i, d: {"steps": 4000 if d < TODAY - timedelta(days=15) else 9000, "sleep_h": 7})
        result = health.before_after(self.root, "steps", (TODAY - timedelta(days=15)).isoformat())
        self.assertTrue(result["enough_data"])
        self.assertGreater(result["change_pct"], 100)
        self.assertTrue(any(l.startswith("- pasos") for l in health.week(self.root, TODAY)))

    def test_goal_progress_from_real_data(self):
        self.days(10, lambda i, d: {"sleep_h": 6.3})
        progress = health.goal_progress(self.root, "sleep_h", 7, today=TODAY)
        self.assertEqual(progress["percent"], 90)
        self.assertFalse(progress["met"])
        self.assertEqual(health.goal_progress(self.root, "rhr", 60, "at_most", today=TODAY), None)  # no data

    def test_a_daily_habit_is_a_streak_counted_to_yesterday(self):
        self.days(12, lambda i, d: {"steps": 11000 if i <= 5 else 3000})
        run = health.streak(self.root, "steps", 10000, today=TODAY)
        self.assertEqual((run["streak"], run["best"], run["today"]), (4, 5, True))
        goal = health.goal_progress(self.root, "steps", 10000, today=TODAY, daily=True)
        self.assertIn("4 días seguidos", goal["average"])

    def test_medication_missed_yesterday_is_named_and_streaks_count_full_days(self):
        self.days(6, lambda i, d: {"meds_due": 2, "meds_taken": 2})
        yesterday = (TODAY - timedelta(days=1)).isoformat()
        health.save(self.root, [{"date": yesterday, "meds_due": 2, "meds_taken": 1, "meds_missed": ["Omeprazol"]}])
        self.assertIn("- medicación ayer: sin marcar como tomada — Omeprazol", health.notable(self.root, TODAY))
        self.assertEqual(health.streak(self.root, "meds_all", 1, today=TODAY)["streak"], 0)

    def test_bad_rows_are_dropped(self):
        health.save(self.root, [{"date": "ayer", "sleep_h": 7}, {"date": "2026-09-01", "sleep_h": -1},
                                {"date": "2026-09-02", "steps": True}])
        self.assertEqual(health.read(self.root)["days"], {})


if __name__ == "__main__":
    unittest.main()
