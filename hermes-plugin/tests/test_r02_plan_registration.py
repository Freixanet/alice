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

    def test_profile_plugin_reaper_uses_shared_canonical_home(self):
        with tempfile.TemporaryDirectory(prefix="alice-r02-profile-reaper-") as root, \
                patch.dict(sys.modules, {"hermes_constants": SimpleNamespace(
                    get_hermes_home=lambda: str(Path(root) / "profiles" / "bot-a"))}), \
                patch.object(self.plugin, "_errands") as errands:
            ctx = SimpleNamespace(register_tool=lambda **_kw: None)
            self.plugin._register_task_tools(ctx)
            # Legacy sessions, the cutover marker and stop-pending ledger are
            # stored at the shared account root, not in the current profile.
            errands.return_value.arm_cutover_reaper.assert_called_once_with(Path(root))

    def test_previously_registered_legacy_tools_are_quarantined_on_sticky_cutover(self):
        """Registration before cutover must not leave live vault/CDP handlers."""
        with tempfile.TemporaryDirectory(prefix="alice-r02-legacy-handler-") as root, \
                patch.dict(sys.modules, {"hermes_constants": SimpleNamespace(get_hermes_home=lambda: root)}), \
                patch.dict("os.environ", {"ALICE_R02_ASR_ONLY": "no"}):
            registered = {}
            llm = Mock(return_value=SimpleNamespace(parsed={"action": "stop", "epoch": 0}))
            ctx = SimpleNamespace(register_tool=lambda **kw: registered.__setitem__(kw["name"], kw),
                                  llm=SimpleNamespace(complete_structured=llm))
            self.plugin._register_task_tools(ctx)
            # A cutover can occur AFTER Hermes has cached all tool callbacks.
            with patch.dict("os.environ", {"ALICE_R02_ASR_ONLY": "yes"}):
                for name, tool in registered.items():
                    if tool["toolset"] != "alice_tasks":
                        continue
                    with self.subTest(name=name):
                        result = json.loads(tool["handler"]({}))
                        self.assertFalse(result["ok"])
                        self.assertEqual(result["mode"], "asr_only")
                self.assertTrue((Path(root) / ".alice" / "r02-asr-only-v1").exists())
            # Losing the environment setting MUST NOT revive those callbacks.
            for name in ("login_fill", "login_request", "purchase_verify",
                         "purchase_check_cart", "checkout_request", "card_request",
                         "errand_dom_read", "errand_start"):
                with self.subTest(sticky=name):
                    result = json.loads(registered[name]["handler"]({}))
                    self.assertFalse(result["ok"])
                    self.assertEqual(result["mode"], "asr_only")
            # A typed planner remains available but never obtains authority.
            planned = json.loads(registered["alice_secure_plan"]["handler"]({
                "goal": "Fictional keyboard", "observations": [], "epoch": 0,
                "state": "active"}))
            self.assertEqual(planned["status"], "proposed")
            self.assertFalse(planned["execution_authority"])
            llm.assert_called_once()

    def test_sticky_cutover_blocks_legacy_receipt_writes_and_old_errand_questions(self):
        with tempfile.TemporaryDirectory(prefix="alice-r02-other-legacy-") as root, \
                patch.dict(sys.modules, {"hermes_constants": SimpleNamespace(get_hermes_home=lambda: root)}), \
                patch.dict("os.environ", {"ALICE_R02_ASR_ONLY": "no"}):
            registered = {}
            ctx = SimpleNamespace(register_tool=lambda **kw: registered.__setitem__(kw["name"], kw))
            receipts = Mock(return_value={"ok": True})
            questions = Mock(return_value={"asked": ["old-question"]})
            purchase_module = SimpleNamespace(
                SCHEMA={"description": "old receipt", "parameters": {"properties": {}}},
                SKILL="legacy", run_tool=receipts)
            ask_module = SimpleNamespace(SCHEMA={"description": "ask"}, run_tool=questions)
            with patch.object(self.plugin, "_purchases", return_value=purchase_module), \
                    patch.object(self.plugin, "_ask_person", return_value=ask_module), \
                    patch.object(self.plugin, "_keep_ask_person_visible"), \
                    patch.object(self.plugin, "_conversation_key", return_value="errand-old-1"):
                self.plugin._register_purchase_tools(ctx)
                self.plugin._register_ask_tools(ctx)
                with patch.dict("os.environ", {"ALICE_R02_ASR_ONLY": "yes"}):
                    self.assertTrue(self.plugin._errands().legacy_payment_blocked(Path(root)))
                for name in ("purchase_outcome", "ask_person"):
                    with self.subTest(name=name):
                        result = json.loads(registered[name]["handler"]({}))
                        self.assertFalse(result["ok"])
                        self.assertEqual(result["mode"], "asr_only")
            receipts.assert_not_called()
            questions.assert_not_called()

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
