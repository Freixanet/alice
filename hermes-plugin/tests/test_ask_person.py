"""ask_person returns at once, parks the task's goal while a question is open, and keeps details.

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
PATH = Path(__file__).resolve().parents[1] / "ask_person.py"
spec = importlib.util.spec_from_file_location("alice_ask_person_test", PATH)
ask = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ask)

try:
    import hermes_cli.goals as goals
except ImportError:  # pragma: no cover - Hermes not on the path
    goals = None


class AskPersonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)

    def test_returns_at_once_with_the_questions_asked(self):
        result = ask.run_tool(self.home, {"questions": [
            {"id": "pago", "question": "¿Cómo pagas?", "choices": ["Tarjeta", "PayPal"]},
            {"id": "nif", "question": "Tu NIF", "field": "id"},
        ]}, "")
        self.assertTrue(result["ok"])
        self.assertEqual(result["asked"], ["pago", "nif"])
        self.assertEqual(result["known"], {})

    def test_kept_details_are_never_asked_again(self):
        ask.save_details(self.home, {"address": "Carrer Major 1", "phone": "600000000"})
        result = ask.run_tool(self.home, {"questions": [
            {"id": "dir", "question": "Dirección", "field": "address"},
            {"id": "mail", "question": "Email", "field": "email"},
        ]}, "s1")
        self.assertEqual(result["known"], {"dir": "Carrer Major 1"})
        self.assertEqual(result["asked"], ["mail"])

    def test_an_answer_is_kept_and_closes_its_question(self):
        ask.run_tool(self.home, {"questions": [{"id": "mail", "question": "Email", "field": "email"}]}, "s1")
        self.assertIn("mail", ask.open_questions(self.home, "s1"))
        answered = ask.absorb(self.home, "s1", [{"role": "user", "content": "[respuesta:mail] a@b.es"}])
        self.assertTrue(answered)
        self.assertEqual(ask.open_questions(self.home, "s1"), {})
        self.assertEqual(ask.load_details(self.home)["email"], "a@b.es")

    def test_sign_in_is_left_to_the_sign_in_card(self):
        result = ask.run_tool(self.home, {"questions": [
            {"id": "login", "question": "Inicia sesión o crea una cuenta de HSN"}]}, "s1")
        self.assertFalse(result["ok"])
        self.assertIn("browser_vault_save_login", result["error"])
        self.assertEqual(ask.open_questions(self.home, "s1"), {})

    def test_answers_are_read_line_by_line(self):
        self.assertEqual(ask.answers_in("[respuesta:a] uno\n[respuesta:b] dos dos\nhola"),
                         {"a": "uno", "b": "dos dos"})


@unittest.skipIf(goals is None, "Hermes is not on the path")
class GoalWaitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = mock.patch.dict(os.environ, {"HERMES_HOME": self.tmp.name})
        env.start()
        self.addCleanup(env.stop)
        self.home = Path(self.tmp.name)
        self.manager = goals.GoalManager(session_id="s-goal")
        self.manager.set("Comprar creatina", max_turns=12)

    def test_an_open_question_parks_the_goal_and_its_answer_releases_it(self):
        ask.run_tool(self.home, {"questions": [{"id": "pago", "question": "¿Cómo pagas?"}]}, "s-goal")
        self.assertTrue(goals.GoalManager(session_id="s-goal").is_waiting())
        ask.absorb(self.home, "s-goal", [{"role": "user", "content": "[respuesta:pago] Tarjeta"}])
        manager = goals.GoalManager(session_id="s-goal")
        self.assertFalse(manager.is_waiting())
        # And the judge learns it was asked and answered, so it is not asked again.
        self.assertIn("¿Cómo pagas?", manager.state.goal)
        self.assertIn("Tarjeta", manager.state.goal)
        self.assertIn("manda sobre lo pedido", manager.state.goal)


if __name__ == "__main__":
    unittest.main()
