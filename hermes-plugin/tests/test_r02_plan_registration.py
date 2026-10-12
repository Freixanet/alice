"""Official Hermes plugin tool registration, with all LLM calls mocked."""

import importlib.util
import json
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


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
        self.assertEqual(tool["toolset"], "alice_secure_planning")
        self.assertIn("state", tool["schema"]["parameters"]["required"])
        outcome = json.loads(tool["handler"]({"goal": "Research keyboards", "epoch": 0,
                                               "observations": [], "state": "active"}))
        self.assertEqual(outcome["status"], "proposed")
        self.assertEqual(outcome["proposal"], {"action": "search", "query": "keyboard", "epoch": 0})
        self.assertFalse(outcome["execution_authority"])
        llm.assert_called_once()
        # A model-written checkout command is never relayed as an executable op.
        llm.return_value = SimpleNamespace(parsed={"action": "checkout_commit", "epoch": 0})
        rejection = json.loads(tool["handler"]({"goal": "Pay now", "epoch": 0,
                                                 "observations": [], "state": "active"}))
        self.assertEqual(rejection["status"], "denied")
        self.assertNotIn("proposal", rejection)

    def test_no_llm_facade_fails_closed(self):
        registered = {}
        ctx = SimpleNamespace(register_tool=lambda **kw: registered.__setitem__(kw["name"], kw))
        self.plugin._register_task_tools(ctx)
        blocked = json.loads(registered["alice_secure_plan"]["handler"](
            {"goal": "Search keyboards", "epoch": 0, "observations": [], "state": "active"}))
        self.assertEqual(blocked["status"], "denied")

    def test_official_plugin_initialization_arms_reaper_without_dashboard_poll(self):
        with tempfile.TemporaryDirectory(prefix="alice-r02-register-startup-") as root, \
                patch.dict(sys.modules, {"hermes_constants": SimpleNamespace(get_hermes_home=lambda: root)}), \
                patch.object(self.plugin, "_errands") as errands:
            ctx = SimpleNamespace(register_tool=lambda **_kw: None)
            self.plugin._register_task_tools(ctx)
            errands.return_value.arm_cutover_reaper.assert_called_once_with(Path(root))

    def test_complete_plugin_registration_cannot_duplicate_secure_planner(self):
        registered = {}
        def register_tool(**kwargs):
            if kwargs["name"] in registered:
                raise AssertionError("duplicate Hermes tool name: " + kwargs["name"])
            registered[kwargs["name"]] = kwargs
        ctx = SimpleNamespace(
            register_tool=register_tool, register_hook=lambda *_a: None,
            register_system_prompt_section=lambda *_a: None,
            llm=SimpleNamespace(complete_structured=lambda **kw:
                SimpleNamespace(parsed={"action": "stop", "epoch": 0})),
        )
        # All non-R02 registrations are irrelevant and may start resident
        # helpers. Patch ONLY those functions, never personal Hermes services.
        bypass = ("_register_goal_tools", "_register_feed_tools",
                  "_register_ask_tools", "_register_purchase_tools",
                  "_register_place_tools", "_register_health_tools",
                  "_register_notes_tools", "_register_agent_tools",
                  "_register_debug_tools", "_register_calendar_tools",
                  "_register_work_tools", "_pause_chat_goals")
        with ExitStack() as scope:
            for name in bypass:
                scope.enter_context(patch.object(self.plugin, name))
            scope.enter_context(patch.object(self.plugin, "_free_web",
                                            return_value=SimpleNamespace(register=lambda _ctx: None)))
            self.plugin.register(ctx)
        self.assertEqual(set(registered).intersection({"alice_secure_plan"}),
                         {"alice_secure_plan"})
        tool = registered["alice_secure_plan"]
        self.assertEqual(tool["toolset"], "alice_secure_planning")
        self.assertIn("state", tool["schema"]["parameters"]["required"])


if __name__ == "__main__":
    unittest.main()
