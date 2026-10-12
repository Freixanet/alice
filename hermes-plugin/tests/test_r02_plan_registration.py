"""Official Hermes plugin tool registration, with all LLM calls mocked."""

import importlib.util
import json
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock


PLUGIN = Path(__file__).resolve().parents[1] / "__init__.py"


class PlannerRegistrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("alice_r02_register_test", PLUGIN)
        cls.plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.plugin)

    def test_official_tool_has_no_runner_access_and_returns_only_untrusted_proposal(self):
        registered = {}
        llm = Mock(return_value=SimpleNamespace(parsed={"action": "search", "query": "keyboard", "epoch": 0}))
        ctx = SimpleNamespace(
            register_tool=lambda **kwargs: registered.__setitem__(kwargs["name"], kwargs),
            llm=SimpleNamespace(complete_structured=llm),
        )
        self.plugin._register_task_tools(ctx)
        tool = registered["alice_secure_plan"]
        self.assertEqual(tool["toolset"], "alice_shopping_plan")
        outcome = json.loads(tool["handler"]({"goal": "Research keyboards", "epoch": 0, "observations": []}))
        self.assertTrue(outcome["ok"])
        self.assertEqual(outcome["proposal"], {"action": "search", "query": "keyboard", "epoch": 0})
        self.assertEqual(outcome["authority"], "none")
        llm.assert_called_once()
        # A model-written checkout command is never relayed as an executable op.
        llm.return_value = SimpleNamespace(parsed={"action": "checkout_commit", "epoch": 0})
        rejection = json.loads(tool["handler"]({"goal": "Pay now", "epoch": 0, "observations": []}))
        self.assertFalse(rejection["ok"])
        self.assertNotIn("proposal", rejection)

    def test_no_llm_facade_fails_closed(self):
        registered = {}
        ctx = SimpleNamespace(register_tool=lambda **kw: registered.__setitem__(kw["name"], kw))
        self.plugin._register_task_tools(ctx)
        blocked = json.loads(registered["alice_secure_plan"]["handler"](
            {"goal": "Search keyboards", "epoch": 0, "observations": []}))
        self.assertFalse(blocked["ok"])


if __name__ == "__main__":
    unittest.main()
