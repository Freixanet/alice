"""The Business team talks only among itself, run with the Hermes virtualenv:

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import yaml

sys.dont_write_bytecode = True
PLUGIN_INIT = Path(__file__).resolve().parents[1] / "__init__.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("hermes_plugin_alice_init_test", PLUGIN_INIT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BusinessIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plugin = load_plugin()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.profile("chief-of-staff", {"alice": {"channel": "Business (Beta)", "order": 0}})
        self.profile("biz-mercado", {"alice": {"channel": "business (beta)", "section": "Intelligence Dept."}})
        self.profile("radar-ia", {"hermes-bots": {"title": "Radar IA"}})
        self.profile("inbox", None)
        self.profile("evals-sandbox", {"alice": {"internal": True}, "hermes-bots": {"hidden": True}})

    def tearDown(self):
        self.tmp.cleanup()

    def profile(self, name, ui_meta):
        folder = self.root / "profiles" / name
        folder.mkdir(parents=True)
        data = {"name": name}
        if ui_meta is not None:
            data["ui_meta"] = ui_meta
        (folder / "profile.yaml").write_text(yaml.safe_dump(data))

    def verdict(self, sender, target):
        return self.plugin.business_verdict(self.root, sender, target)

    def test_membership_comes_from_the_business_placement(self):
        self.assertEqual(self.plugin.business_members(self.root), {"chief-of-staff", "biz-mercado"})

    def test_nobody_writes_to_or_from_an_internal_profile(self):
        self.assertEqual(self.plugin.internal_profiles(self.root), {"evals-sandbox"})
        for sender in ("radar-ia", "chief-of-staff", "default"):
            self.assertIn("interno", self.verdict(sender, "evals-sandbox"))
        self.assertIn("interno", self.verdict("evals-sandbox", "inbox"))

    def test_the_team_talks_among_itself(self):
        self.assertIsNone(self.verdict("chief-of-staff", "biz-mercado"))
        self.assertIsNone(self.verdict("biz-mercado", "@chief-of-staff"))

    def test_the_team_cannot_write_outside(self):
        for target in ("radar-ia", "hermes", "casa/radar-ia", "radar-ia@portatil", "nadie"):
            reason = self.verdict("biz-mercado", target)
            self.assertIsNotNone(reason, target)
            self.assertIn("@chief-of-staff", reason)
            self.assertNotIn("@biz-mercado", reason)

    def test_nobody_outside_can_write_to_the_team(self):
        self.assertIn("@biz-mercado", self.verdict("radar-ia", "biz-mercado"))
        self.assertIsNotNone(self.verdict("default", "chief-of-staff"))

    def test_outside_agents_keep_talking_to_each_other(self):
        self.assertIsNone(self.verdict("radar-ia", "inbox"))
        self.assertIsNone(self.verdict("default", "radar-ia"))

    def test_without_a_business_team_nothing_is_blocked(self):
        empty = Path(self.tmp.name) / "vacio"
        (empty / "profiles" / "radar-ia").mkdir(parents=True)
        self.assertIsNone(self.plugin.business_verdict(empty, "radar-ia", "inbox"))

    def test_the_hook_blocks_as_the_calling_profile(self):
        fake = types.ModuleType("hermes_constants")
        fake.get_hermes_home = lambda: self.root / "profiles" / "biz-mercado"
        with mock.patch.dict(sys.modules, {"hermes_constants": fake}):
            blocked = self.plugin._pre_tool_call(tool_name="message_agent", args={"target": "radar-ia"})
            allowed = self.plugin._pre_tool_call(tool_name="message_agent", args={"target": "chief-of-staff"})
            other_tool = self.plugin._pre_tool_call(tool_name="web_search", args={"target": "radar-ia"})
        self.assertEqual(blocked["action"], "block")
        self.assertIsNone(allowed)
        self.assertIsNone(other_tool)

    def test_the_root_profile_is_alice(self):
        fake = types.ModuleType("hermes_constants")
        fake.get_hermes_home = lambda: self.root
        with mock.patch.dict(sys.modules, {"hermes_constants": fake}):
            blocked = self.plugin._pre_tool_call(tool_name="message_agent", args={"target": "biz-mercado"})
        self.assertEqual(blocked["action"], "block")

    def test_when_the_rule_cannot_be_checked_the_message_does_not_go(self):
        fake = types.ModuleType("hermes_constants")

        def broken():
            raise RuntimeError("no home")

        fake.get_hermes_home = broken
        with mock.patch.dict(sys.modules, {"hermes_constants": fake}):
            blocked = self.plugin._pre_tool_call(tool_name="message_agent", args={"target": "inbox"})
        self.assertEqual(blocked["action"], "block")

    def test_each_agent_is_told_whom_it_may_message(self):
        inside = self.plugin.team_prompt_for(self.root, "biz-mercado")
        self.assertIn("solo puedes escribir a: @chief-of-staff", inside)
        # Inside the team, the others are not named as unavailable: naming them
        # is what had the lead answering with who it could not reach.
        self.assertIn("no existen para ti", inside)
        outside = self.plugin.team_prompt_for(self.root, "radar-ia")
        self.assertIn("@biz-mercado, @chief-of-staff", outside)
        self.assertIn("no están disponibles para ti", outside)
        self.assertIn("interno", self.plugin.team_prompt_for(self.root, "evals-sandbox"))
        empty = Path(self.tmp.name) / "vacio"
        (empty / "profiles" / "radar-ia").mkdir(parents=True)
        self.assertEqual(self.plugin.team_prompt_for(empty, "radar-ia"), "")

    def test_register_adds_the_hooks_and_the_prompt_section(self):
        ctx = mock.Mock()
        self.plugin.register(ctx)
        # The Business boundary, and the observer that keeps Activity's record of actions.
        ctx.register_hook.assert_any_call("pre_tool_call", self.plugin._pre_tool_call)
        ctx.register_hook.assert_any_call("post_tool_call", self.plugin._post_tool_call)
        # And the shared browser is started before an agent browses.
        ctx.register_hook.assert_any_call("pre_tool_call", self.plugin._browser_ready)
        self.assertEqual(ctx.register_hook.call_count, 3)
        ctx.register_system_prompt_section.assert_any_call("alice.equipos", self.plugin.team_prompt)
        ctx.register_system_prompt_section.assert_any_call("alice.debug", self.plugin.debug_prompt)
        # And the person's open goals, so the agent keeps them current.
        ctx.register_system_prompt_section.assert_any_call("alice.objetivos", self.plugin.goals_prompt)
        self.assertEqual(ctx.register_system_prompt_section.call_count, 3)


if __name__ == "__main__":
    unittest.main()
