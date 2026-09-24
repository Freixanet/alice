"""Taking over the shared browser: agents wait while the person holds it, get it back when
handed back, and a forgotten takeover lapses.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("alice_browser_live_control_test", HERE / "browser_live.py")
bl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bl)


class BrowserControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_agents_hold_it_until_the_person_takes_over_and_hands_back(self):
        self.assertEqual(bl.control(self.root, now=100)["holder"], "agent")
        self.assertEqual(bl.take_over(self.root, now=100)["holder"], "human")
        self.assertEqual(bl.control(self.root, now=200)["holder"], "human")
        self.assertEqual(bl.hand_back(self.root, now=300)["holder"], "agent")

    def test_a_forgotten_takeover_lapses_and_use_keeps_it_fresh(self):
        bl.take_over(self.root, now=0)
        bl.touched(self.root, now=bl.LEASE_IDLE_SECONDS - 10)
        self.assertEqual(bl.control(self.root, now=bl.LEASE_IDLE_SECONDS + 5)["holder"], "human")
        self.assertEqual(bl.control(self.root, now=2 * bl.LEASE_IDLE_SECONDS + 1)["holder"], "agent")
        self.assertTrue(json.loads((self.root / bl.LEASE).read_text())["lapsed"])

    def test_the_agents_browser_tools_wait_while_the_person_holds_it(self):
        plugin_spec = importlib.util.spec_from_file_location("hermes_plugin_alice_control_test", HERE / "__init__.py")
        plugin = importlib.util.module_from_spec(plugin_spec)
        plugin_spec.loader.exec_module(plugin)
        fake = mock.Mock(managed=lambda root: True, control=lambda root: {"holder": "human"})
        with mock.patch.object(plugin, "_browser", return_value=fake), \
             mock.patch.object(plugin, "_hermes_root", return_value=self.root):
            blocked = plugin._browser_ready(tool_name="browser_exec")
            self.assertEqual(blocked["action"], "block")
            self.assertIn("taken over", blocked["message"])
            self.assertIsNone(plugin._browser_ready(tool_name="web_search"))
            fake.control = lambda root: {"holder": "agent"}
            self.assertIsNone(plugin._browser_ready(tool_name="browser_navigate"))
            fake.ensure.assert_called()


class FollowTheAgentTests(unittest.TestCase):
    def setUp(self):
        bl._seen.clear()
        bl._changed.clear()

    def test_the_view_follows_the_tab_where_something_last_happened(self):
        old = {"id": "a", "url": "https://rodalies.gencat.cat/", "title": "Cookies"}
        self.assertEqual(bl.busiest([old], now=1)["id"], "a")
        # The agent opens its own tab: that is where to look.
        mine = {"id": "b", "url": "about:blank", "title": ""}
        self.assertEqual(bl.busiest([old, mine], now=2)["id"], "b")
        mine = {"id": "b", "url": "https://rodalies.gencat.cat/horaris", "title": "Horaris"}
        self.assertEqual(bl.busiest([old, mine], now=3)["id"], "b")
        # Then something happens in the first one again.
        old = {"id": "a", "url": "https://www.renfe.com/", "title": "Renfe"}
        self.assertEqual(bl.busiest([old, mine], now=4)["id"], "a")
        # A closed tab is forgotten.
        self.assertEqual(bl.busiest([mine], now=5)["id"], "b")
        self.assertNotIn("a", bl._seen)
        self.assertIsNone(bl.busiest([], now=6))

    def test_on_a_first_look_the_list_order_decides(self):
        tabs = [{"id": "x", "url": "https://a.com", "title": "A"}, {"id": "y", "url": "https://b.com", "title": "B"}]
        self.assertEqual(bl.busiest(tabs, now=1)["id"], "x")


if __name__ == "__main__":
    unittest.main()
