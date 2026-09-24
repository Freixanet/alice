"""Goals: a plan per goal, progress as steps are done, a short log, routines linked, and the
agent's view of them.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_goals_test", Path(__file__).resolve().parents[1] / "goals.py")
gm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gm)


class GoalsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.clock = [1000.0]
        self.goals = gm.Goals(Path(self.tmp.name), now=lambda: self.clock[0])

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_measured_goal_reads_its_progress_from_health(self):
        out = gm.run_tool(self.goals, {"action": "create", "title": "Dormir 7 h", "metric": "sleep_h",
                                       "target": 7, "window_days": 7})
        self.assertEqual(out["goal"]["measure"], {"metric": "sleep_h", "target": 7.0, "direction": "at_least",
                                                  "window_days": 7})
        reading = {"average": "6 h 18 min", "percent": 90, "met": False}
        listed = gm.run_tool(self.goals, {"action": "list"}, measured=lambda g: reading)
        self.assertEqual(listed["goals"][0]["measured"], reading)
        self.assertIn("media 6 h 18 min = 90 %", gm.summary(self.goals.list(), measured=lambda g: reading))
        bad = gm.run_tool(self.goals, {"action": "create", "title": "x", "metric": "steps", "target": "mucho"})
        self.assertFalse(bad["ok"])

    def test_a_goal_with_its_plan_progresses_step_by_step(self):
        goal = self.goals.create("Vuelta al cole", "Que no se escape nada", "2026-09-30",
                                 ["Leer los correos del colegio", "Comprar el material", "Reservar la cena"])
        self.assertEqual(gm.Goals.progress(goal), {"done": 0, "total": 3})
        first = goal["steps"][0]["id"]
        goal = self.goals.step(goal["id"], step_id=first, status="done")
        self.assertEqual(gm.Goals.progress(goal), {"done": 1, "total": 3})
        self.assertEqual(gm.Goals.next_step(goal)["text"], "Comprar el material")
        self.assertIn("Done: Leer los correos del colegio", [e["text"] for e in goal["log"]])
        goal = self.goals.step(goal["id"], add=["Inscribir en las pruebas"])
        self.assertEqual(len(goal["steps"]), 4)
        goal = self.goals.update(goal["id"], status="done", note="Todo listo")
        self.assertEqual(goal["status"], "done")
        self.assertEqual(self.goals.list(include_done=False), [])

    def test_bad_input_is_refused_plainly(self):
        with self.assertRaises(gm.GoalError):
            self.goals.create("  ")
        goal = self.goals.create("Correr una media maratón", due="marzo")
        self.assertIsNone(goal["due"])  # not a date: not kept
        with self.assertRaises(gm.GoalError):
            self.goals.update(goal["id"], status="finished")
        with self.assertRaises(gm.GoalError):
            self.goals.step(goal["id"], step_id="nope", status="done")

    def test_the_tool_and_the_prompt(self):
        made = gm.run_tool(self.goals, {"action": "create", "title": "Piso en Manresa",
                                        "steps": ["Fijar presupuesto", "Vigilar Idealista"]})
        self.assertTrue(made["ok"])
        goal_id = made["goal"]["id"]
        self.assertTrue(gm.run_tool(self.goals, {"action": "link_routine", "goal_id": goal_id,
                                                 "routine": "abc123"})["ok"])
        listed = gm.run_tool(self.goals, {"action": "list"})["goals"]
        self.assertEqual(listed[0]["next"]["text"], "Fijar presupuesto")
        self.assertFalse(gm.run_tool(self.goals, {"action": "update"})["ok"])
        prompt = gm.prompt_section(self.goals.list(include_done=False))
        self.assertIn(f"[{goal_id}] Piso en Manresa", prompt)
        self.assertIn("0/2 steps", prompt)
        self.assertIn("next: Fijar presupuesto", prompt)
        self.assertEqual(self.goals.get(goal_id)["routines"], ["abc123"])

    def test_open_goals_come_first_and_the_log_stays_short(self):
        a = self.goals.create("A")
        self.clock[0] += 10
        b = self.goals.create("B")
        self.goals.update(a["id"], status="done")
        self.assertEqual([g["title"] for g in self.goals.list()], ["B", "A"])
        for n in range(gm.MAX_LOG + 10):
            self.goals.update(b["id"], note=f"nota {n}")
        self.assertEqual(len(self.goals.get(b["id"])["log"]), gm.MAX_LOG)


if __name__ == "__main__":
    unittest.main()
