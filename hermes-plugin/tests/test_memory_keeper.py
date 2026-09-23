"""Memory that keeps itself tidy: origins, conservative cleanup, dry-run and undo.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "alice_memory_keeper_test", Path(__file__).resolve().parents[1] / "memory_keeper.py")
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)

TODAY = date(2026, 9, 23)
NOW = 1790150000.0  # 2026-09-23


class FakeFiles:
    """What Hermes' MemoryStore does that matters here: exact entries, substring removal."""

    def __init__(self, memory=(), user=()):
        self.data = {"memory": list(memory), "user": list(user)}
        self.writes = 0

    def entries(self, target):
        return list(self.data[target])

    def remove(self, target, text):
        matches = [i for i, e in enumerate(self.data[target]) if text in e]
        if len(matches) != 1:
            return "ambiguous or missing"
        self.data[target].pop(matches[0])
        self.writes += 1
        return None

    def add(self, target, text):
        if text in self.data[target]:
            return None
        self.data[target].append(text)
        self.writes += 1
        return None


class KeeperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.clock = [NOW]

    def tearDown(self):
        self.temp.cleanup()

    def keeper(self, files):
        return mk.Keeper(self.home, files, now=lambda: self.clock[0])

    def test_old_entries_without_metadata_keep_working(self):
        files = FakeFiles(user=["Vive en Valencia", "Prefiere respuestas cortas"])
        keeper = self.keeper(files)
        rows = keeper.scan("user")
        self.assertEqual([r["text"] for r in rows], ["Vive en Valencia", "Prefiere respuestas cortas"])
        self.assertEqual({r["source"] for r in rows}, {"legacy"})
        origin = keeper.origin("user", text="Vive en Valencia")
        self.assertEqual(origin["source"], "legacy")
        self.assertFalse(origin["known"])
        # The memory files themselves were never rewritten.
        self.assertEqual(files.writes, 0)

    def test_origin_of_an_agent_entry_names_its_conversation(self):
        files = FakeFiles(user=["Vive en Valencia"])
        keeper = self.keeper(files)
        keeper.scan("user")
        files.data["user"].append("Tiene un perro llamado Lur")
        keeper.record("user", "Tiene un perro llamado Lur", "agent", session="20260923_101010_abc", profile="default")
        origin = keeper.origin("user", text="Tiene un perro llamado Lur")
        self.assertEqual((origin["source"], origin["session"], origin["profile"]),
                         ("agent", "20260923_101010_abc", "default"))

    def test_dry_run_changes_nothing(self):
        files = FakeFiles(memory=["Usa el modelo Luna", "usa el modelo luna."])
        keeper = self.keeper(files)
        result = keeper.run(today=TODAY)
        self.assertFalse(result["apply"])
        self.assertEqual(len(result["proposals"]), 1)
        self.assertEqual(result["applied"], [])
        self.assertEqual(files.data["memory"], ["Usa el modelo Luna", "usa el modelo luna."])
        self.assertEqual(files.writes, 0)
        self.assertEqual(keeper.changes(), [])

    def test_a_duplicate_is_merged_then_reverted(self):
        files = FakeFiles(memory=["Usa el modelo Luna", "usa el  modelo LUNA."])
        keeper = self.keeper(files)
        keeper.set_apply(True)
        result = keeper.run(today=TODAY)
        self.assertEqual(len(result["applied"]), 1)
        self.assertEqual(files.data["memory"], ["Usa el modelo Luna"])
        change = keeper.changes()[0]
        self.assertEqual(change["kind"], "duplicate")
        self.assertEqual(change["removed"][0]["text"], "usa el  modelo LUNA.")
        keeper.revert(change["id"])
        self.assertIn("usa el  modelo LUNA.", files.data["memory"])
        self.assertIsNotNone(keeper.changes()[0]["reverted_at"])
        # Put back by the person: not merged again on the next pass.
        self.assertEqual(keeper.run(today=TODAY)["applied"], [])
        self.assertEqual(len(files.data["memory"]), 2)

    def test_a_dated_event_that_passed_expires(self):
        files = FakeFiles(user=["Vive en Valencia"])
        keeper = self.keeper(files)
        keeper.scan("user")
        self.clock[0] = NOW - 20 * 86400
        for text in ("Tiene cita con el dentista el 12 de septiembre", "Vuelo a Roma el 30/09/2026",
                     "Nació el 3 de mayo de 1990"):
            files.data["user"].append(text)
            keeper.record("user", text, "agent", session="s")
        self.clock[0] = NOW
        proposals = keeper.propose("user", today=TODAY)
        self.assertEqual([(p["kind"], p["remove"][0]["text"]) for p in proposals],
                         [("expired", "Tiene cita con el dentista el 12 de septiembre")])

    def test_a_newer_ya_no_retires_what_it_contradicts(self):
        files = FakeFiles(user=["Marcos vive en Valencia"])
        keeper = self.keeper(files)
        keeper.scan("user")
        self.clock[0] = NOW + 60
        files.data["user"].append("Marcos ya no vive en Valencia")
        keeper.record("user", "Marcos ya no vive en Valencia", "agent", session="s")
        proposals = keeper.propose("user", today=TODAY)
        self.assertEqual(len(proposals), 1)
        self.assertEqual(proposals[0]["kind"], "contradiction")
        self.assertEqual(proposals[0]["remove"][0]["text"], "Marcos vive en Valencia")
        self.assertEqual(proposals[0]["keep"]["text"], "Marcos ya no vive en Valencia")

    def test_hand_edited_entries_are_never_touched(self):
        files = FakeFiles(memory=["Usa el modelo Luna"])
        keeper = self.keeper(files)
        keeper.set_apply(True)
        keeper.scan("memory")
        # Written in the file by hand after Alice first looked: a duplicate, a dated event
        # long past, and a claim a newer "ya no" contradicts.
        hand = ["usa el modelo luna.", "Reunión con Ana el 1/09/2026", "El proyecto Beta sigue en marcha"]
        files.data["memory"] += hand
        self.clock[0] = NOW + 60
        files.data["memory"].append("El proyecto Beta ya no sigue en marcha")
        keeper.record("memory", "El proyecto Beta ya no sigue en marcha", "agent", session="s")
        keeper.run(today=TODAY)
        for text in hand:
            self.assertIn(text, files.data["memory"])
            self.assertEqual(keeper.origin("memory", text=text)["source"], "hand")
        # The person's own edits from the app are protected the same way.
        files.data["user"] = ["Cita con Luis el 2/09/2026"]
        keeper.scan("user")
        keeper.record("user", "Cita con Luis el 2/09/2026", "person")
        keeper.run(today=TODAY)
        self.assertEqual(files.data["user"], ["Cita con Luis el 2/09/2026"])

    def test_a_revert_that_does_not_fit_says_so(self):
        files = FakeFiles(memory=["Usa Luna", "usa luna"])
        keeper = self.keeper(files)
        keeper.set_apply(True)
        change = keeper.run(today=TODAY)["applied"][0]
        files.add = lambda target, text: "Memory at 2,200/2,200 chars"
        with self.assertRaises(RuntimeError):
            keeper.revert(change["id"])
        self.assertIsNone(keeper.changes()[0]["reverted_at"])

    def test_nothing_is_removed_without_its_text_on_record(self):
        files = FakeFiles(user=["Le gusta el café", "le gusta el café"])
        keeper = self.keeper(files)
        keeper.set_apply(True)
        keeper.run(today=TODAY)
        stored = json.loads((self.home / mk.DIR / "changes.json").read_text())
        self.assertEqual(stored[0]["removed"][0]["text"], "le gusta el café")


if __name__ == "__main__":
    unittest.main()


class HermesStoreTests(unittest.TestCase):
    """The same round trip through Hermes' own MemoryStore, when Hermes is importable."""

    def setUp(self):
        try:
            import tools.memory_tool  # noqa: F401
        except ImportError:
            self.skipTest("Hermes is not importable here")
        import os
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        from hermes_constants import reset_hermes_home_override, set_hermes_home_override
        token = set_hermes_home_override(str(self.home))
        self.addCleanup(reset_hermes_home_override, token)
        (self.home / "memories").mkdir()
        (self.home / "memories" / "MEMORY.md").write_text("Usa el modelo Luna\n§\nusa el modelo luna.")
        _ = os

    def test_merge_and_revert_through_hermes(self):
        from tools.memory_tool import load_on_disk_store
        keeper = mk.Keeper(self.home, mk.HermesFiles(load_on_disk_store()), now=lambda: NOW)
        keeper.set_apply(True)
        change = keeper.run(targets=("memory",), today=TODAY)["applied"][0]
        text = (self.home / "memories" / "MEMORY.md").read_text()
        self.assertEqual(text, "Usa el modelo Luna")
        keeper.revert(change["id"])
        text = (self.home / "memories" / "MEMORY.md").read_text()
        self.assertEqual(text.split("\n§\n"), ["Usa el modelo Luna", "usa el modelo luna."])


class HookTests(unittest.TestCase):
    """What the plugin does when an agent calls the `memory` tool."""

    def setUp(self):
        import types
        from unittest import mock
        spec = importlib.util.spec_from_file_location(
            "hermes_plugin_alice_memory_hook_test", Path(__file__).resolve().parents[1] / "__init__.py")
        self.plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.plugin)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "profiles" / "inbox"
        self.home.mkdir(parents=True)
        self.files = FakeFiles(user=["Vive en Valencia"])
        fake = types.SimpleNamespace(Keeper=mk.Keeper, HermesFiles=lambda: self.files, TARGETS=mk.TARGETS)
        patches = [mock.patch.dict(sys.modules, {"hermes_constants": types.SimpleNamespace(
                       get_hermes_home=lambda: self.home)}),
                   mock.patch.object(self.plugin, "_memory_keeper", return_value=fake),
                   mock.patch.object(self.plugin, "_action_log")]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_an_agent_entry_is_the_agents_not_hand_written(self):
        keeper = mk.Keeper(self.home, self.files)
        keeper.scan("user")
        self.files.data["user"].append("Tiene un perro llamado Lur")
        self.plugin._post_tool_call(tool_name="memory", session_id="s-1", status="ok",
                                    args={"action": "add", "target": "user", "content": "Tiene un perro llamado Lur"})
        origin = keeper.origin("user", text="Tiene un perro llamado Lur")
        self.assertEqual((origin["source"], origin["session"], origin["profile"]), ("agent", "s-1", "inbox"))

    def test_a_batch_records_every_entry(self):
        self.files.data["memory"] = ["Usa Luna", "Prefiere español"]
        self.plugin._post_tool_call(tool_name="memory", session_id="s-2", status="ok", args={"operations": [
            {"action": "add", "target": "memory", "content": "Usa Luna"},
            {"action": "add", "target": "memory", "content": "Prefiere español"}]})
        keeper = mk.Keeper(self.home, self.files)
        self.assertEqual(keeper.origin("memory", text="Prefiere español")["source"], "agent")
