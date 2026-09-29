"""A task an agent takes on stays open in Hermes' goal loop until done or it needs the person.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "task_finish.py"
spec = importlib.util.spec_from_file_location("alice_task_finish_test", PATH)
task_finish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(task_finish)

try:
    import hermes_cli.goals as goals
except ImportError:  # pragma: no cover - Hermes not on the path
    goals = None


@unittest.skipIf(goals is None, "Hermes is not on the path")
class FinishTaskTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = mock.patch.dict(os.environ, {"HERMES_HOME": self.tmp.name})
        env.start()
        self.addCleanup(env.stop)
        self.saved = {}
        patches = [
            mock.patch.object(goals, "save_goal", side_effect=lambda sid, st: self.saved.__setitem__(sid, st.to_json())),
            mock.patch.object(goals, "load_goal", side_effect=lambda sid: goals.GoalState.from_json(self.saved[sid]) if sid in self.saved else None),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_the_task_becomes_an_active_goal_whose_contract_forbids_stopping_at_obstacles(self):
        result = task_finish.start("Comprar 1 saco de pienso en piensosraposo.es",
                                   "Checkout listo en el botón de pagar con 1 unidad", "session-1")
        self.assertTrue(result["ok"])
        state = goals.GoalManager(session_id="session-1").state
        self.assertEqual(state.status, "active")
        self.assertEqual(state.max_turns, task_finish.MAX_TURNS)
        self.assertIn("NEVER a reason to stop", state.contract.stop_when)
        self.assertIn("explicit yes", state.contract.constraints)
        # Done means checked, and what was not checked is said.
        self.assertIn("Sin comprobar", state.contract.constraints)
        self.assertEqual(state.contract.verification, "Checkout listo en el botón de pagar con 1 unidad")

    def test_calling_again_replaces_the_goal(self):
        task_finish.start("Primera", "a", "session-1")
        task_finish.start("Segunda", "b", "session-1")
        self.assertEqual(goals.GoalManager(session_id="session-1").state.goal, "Segunda")

    def test_without_a_session_or_a_task_nothing_is_opened(self):
        self.assertFalse(task_finish.start("Algo", "a", "")["ok"])
        self.assertFalse(task_finish.start("  ", "a", "session-1")["ok"])
        self.assertEqual(self.saved, {})

    def test_the_tool_uses_the_chat_turn_session(self):
        from tools.approval_context import reset_current_session_key, set_current_session_key

        token = set_current_session_key("session-9")
        try:
            self.assertTrue(task_finish.run_tool({"task": "Reservar mesa", "done_when": "confirmación"})["ok"])
        finally:
            reset_current_session_key(token)
        self.assertIn("session-9", self.saved)


@unittest.skipIf(goals is None, "Hermes is not on the path")
class AutoGoalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = mock.patch.dict(os.environ, {"HERMES_HOME": self.tmp.name})
        env.start()
        self.addCleanup(env.stop)

    def test_an_errand_opens_its_goal(self):
        self.assertTrue(task_finish.auto_start("prepárame en el carrito una whey de 1 kg", "s-a"))
        self.assertTrue(goals.GoalManager(session_id="s-a").is_active())

    def test_the_same_reply_twice_pauses_the_goal(self):
        task_finish.auto_start("prepárame en el carrito una whey de 1 kg", "s-r")
        cont = task_finish.CONTINUATION_PREFIX + "\nGoal: x"
        reply = "Comprobado en HSN: hay 2 × Evobasic whey de 500 g chocolate en la cesta; no he comprado."
        self.assertFalse(task_finish.guard_repeat(cont, reply, "s-r"))
        self.assertTrue(task_finish.guard_repeat(cont, reply + " Nada más.", "s-r"))
        self.assertFalse(goals.GoalManager(session_id="s-r").is_active())

    def test_a_question_or_an_answer_does_not(self):
        self.assertFalse(task_finish.auto_start("¿qué tiempo hace mañana?", "s-b"))
        self.assertFalse(task_finish.auto_start("[respuesta:sabor] Chocolate", "s-b"))
        self.assertFalse(goals.GoalManager(session_id="s-b").is_active())


if __name__ == "__main__":
    unittest.main()
