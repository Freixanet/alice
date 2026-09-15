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

    def test_register_adds_the_hook(self):
        ctx = mock.Mock()
        self.plugin.register(ctx)
        ctx.register_hook.assert_called_once_with("pre_tool_call", self.plugin._pre_tool_call)


if __name__ == "__main__":
    unittest.main()
