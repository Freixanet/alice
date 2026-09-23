"""The notes tools drive the profile's own store, run with the Hermes virtualenv:

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests

The real ``inbox.py`` is used: these tools exist so the agent never shells out to it, so the
test that matters is that a tool call and its command leave the store in the same state.
"""
import importlib.util
import json
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PLUGIN_INIT = Path(__file__).resolve().parents[1] / "__init__.py"
STORE_SCRIPT = Path.home() / ".hermes" / "profiles" / "inbox" / "workspace" / "inbox-store" / "inbox.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("hermes_plugin_alice_notes_test", PLUGIN_INIT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(STORE_SCRIPT.is_file(), "no notes store installed")
class NotesToolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plugin = load_plugin()
        cls.tools = {t[0]: t for t in cls.plugin.NOTE_TOOLS}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        store = self.home / "workspace" / "inbox-store"
        store.mkdir(parents=True)
        shutil.copy(STORE_SCRIPT, store / "inbox.py")
        # `get_hermes_home` lives in Hermes itself; the plugin imports it when a tool runs.
        self.patch = mock.patch.dict(
            sys.modules,
            {"hermes_constants": types.SimpleNamespace(get_hermes_home=lambda: self.home)})
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def call(self, name, args=None):
        """A tool call, as the registry makes it, parsed from the JSON the store prints."""
        _, _, _, _, call = self.tools[name]
        out = self.plugin._store_call(lambda m, root: call(args or {}, m, root))
        return json.loads(out)

    # ── capture ──────────────────────────────────────────────────────────────

    def test_add_keeps_the_text_exactly(self):
        text = "  cafetera nueva — ¿la de $¿? 'con comillas' y | tubería\nsegunda línea  "
        added = self.call("note_add", {"text": text})
        self.assertTrue(added["ok"])
        entry = self.call("note_get", {"id": added["id"]})["entry"]
        self.assertEqual(entry["text"], text)

    def test_add_files_into_an_existing_folder_with_tags(self):
        self.call("note_folder_create", {"name": "Salud"})
        added = self.call("note_add", {"text": "correr 5k", "folder": "Salud", "tags": "deporte, rutina"})
        self.assertEqual(added["tags"], ["deporte", "rutina"])
        folders = self.call("note_folders")
        self.assertEqual([(f["name"], f["notes"]) for f in folders["folders"]], [("Salud", 1)])
        self.assertEqual(folders["quick_notes"], 0)

    def test_an_unknown_folder_never_loses_the_note(self):
        added = self.call("note_add", {"text": "nota huérfana", "folder": "No existe"})
        self.assertTrue(added["ok"])
        self.assertIsNone(added["folder"])
        self.assertIn("Quick Notes", added["warning"])
        self.assertEqual(self.call("note_folders")["quick_notes"], 1)

    # ── filing ───────────────────────────────────────────────────────────────

    def test_file_moves_several_notes_at_once(self):
        self.call("note_folder_create", {"name": "Trabajo"})
        ids = [self.call("note_add", {"text": f"nota {i}"})["id"] for i in range(3)]
        filed = self.call("note_file", {"ids": ids, "folder": "Trabajo", "tags": "equipo"})
        self.assertTrue(filed["ok"])
        self.assertEqual(self.call("note_folders")["folders"][0]["notes"], 3)

    def test_file_with_folder_none_returns_a_note_to_quick_notes(self):
        self.call("note_folder_create", {"name": "Ideas"})
        eid = self.call("note_add", {"text": "una idea", "folder": "Ideas"})["id"]
        self.call("note_file", {"ids": [eid]})
        self.assertEqual(self.call("note_folders")["quick_notes"], 1)

    def test_deleting_a_folder_keeps_its_notes(self):
        self.call("note_folder_create", {"name": "Temporal"})
        self.call("note_add", {"text": "sigue viva", "folder": "Temporal"})
        self.assertTrue(self.call("note_folder_delete", {"folder": "Temporal"})["ok"])
        self.assertEqual(self.call("note_folders")["quick_notes"], 1)
        self.assertEqual(self.call("note_recent")["count"], 1)

    def test_renaming_a_folder_keeps_its_notes(self):
        self.call("note_folder_create", {"name": "Ideas"})
        self.call("note_add", {"text": "idea", "folder": "Ideas"})
        self.call("note_folder_rename", {"folder": "Ideas", "name": "Ideas de negocio"})
        folders = self.call("note_folders")["folders"]
        self.assertEqual([(f["name"], f["notes"]) for f in folders], [("Ideas de negocio", 1)])

    # ── recall ───────────────────────────────────────────────────────────────

    def test_search_finds_a_note_by_its_words(self):
        self.call("note_add", {"text": "comprar una cafetera para la oficina"})
        self.call("note_add", {"text": "llamar al dentista"})
        hits = self.call("note_search", {"query": "cafetera"})
        self.assertEqual([h["text"] for h in hits["hits"]], ["comprar una cafetera para la oficina"])

    def test_similar_finds_a_near_duplicate(self):
        self.call("note_add", {"text": "montar un curso de fotografía analógica"})
        hits = self.call("note_similar", {"text": "curso de fotografía analógica"})
        self.assertEqual(hits["count"], 1)

    def test_recent_returns_the_newest_first(self):
        first = self.call("note_add", {"text": "primera"})["id"]
        second = self.call("note_add", {"text": "segunda"})["id"]
        self.assertEqual([h["id"] for h in self.call("note_recent")["hits"]], [second, first])

    def test_digest_week_reports_the_period(self):
        self.call("note_add", {"text": "algo de esta semana"})
        digest = self.call("note_digest_week", {"days": 7})
        self.assertTrue(digest["ok"])
        self.assertEqual(digest["count"], 1)

    # ── the nightly routine ──────────────────────────────────────────────────

    def test_enrich_keeps_the_folder_and_the_tags(self):
        self.call("note_folder_create", {"name": "Salud"})
        eid = self.call("note_add", {"text": "dormir 8h", "folder": "Salud", "tags": "sueño"})["id"]
        self.call("note_enrich", {"id": eid, "payload": {"topics": ["descanso"], "summary": "dormir más"}})
        entry = self.call("note_get", {"id": eid})["entry"]["enrichment"]
        self.assertEqual(entry["tags"], ["sueno"])  # el almacén pliega los acentos
        self.assertEqual(entry["topics"], ["descanso"])
        self.assertTrue(entry["folder"])

    def test_unprocessed_empties_once_marked(self):
        eid = self.call("note_add", {"text": "pendiente"})["id"]
        self.assertEqual(self.call("note_unprocessed")["count"], 1)
        self.assertEqual(self.call("note_mark_processed", {"ids": [eid]})["marked"], [eid])
        self.assertEqual(self.call("note_unprocessed")["count"], 0)

    def test_relate_links_two_notes(self):
        a = self.call("note_add", {"text": "idea de app de notas"})["id"]
        b = self.call("note_add", {"text": "otra idea de app de notas"})["id"]
        related = self.call("note_relate", {"a": a, "b": b, "kind": "similar", "note": "lo mismo"})
        self.assertEqual(related["relation"]["type"], "similar")

    # ── failures are reported, never raised ──────────────────────────────────

    def test_a_missing_note_is_an_error_not_a_crash(self):
        self.assertEqual(self.call("note_get", {"id": "no-existe"}),
                         {"ok": False, "error": "no existe no-existe"})

    def test_relate_refuses_ids_that_do_not_exist(self):
        eid = self.call("note_add", {"text": "sola"})["id"]
        answer = self.call("note_relate", {"a": eid, "b": "fantasma", "kind": "similar"})
        self.assertFalse(answer["ok"])

    def test_a_profile_without_a_store_gets_an_answer(self):
        (self.home / "workspace" / "inbox-store" / "inbox.py").unlink()
        self.assertFalse(self.plugin._has_notes_store())
        answer = self.call("note_folders")
        self.assertFalse(answer["ok"])
        self.assertIn("almacén de notas", answer["error"])

    # ── registration ─────────────────────────────────────────────────────────

    def test_every_tool_is_registered_in_the_notes_toolset(self):
        registered = []

        class Ctx:
            def register_hook(self, *a, **k):
                pass

            def register_system_prompt_section(self, *a, **k):
                pass

            def register_tool(self, **kw):
                registered.append(kw)

        self.plugin.register(Ctx())
        notes = [t for t in registered if t["toolset"] == "notes"]
        agents = [t for t in registered if t["toolset"] == "alice_agents"]
        debug = [t for t in registered if t["toolset"] == "alice_debug"]
        self.assertEqual([t["name"] for t in notes], [t[0] for t in self.plugin.NOTE_TOOLS])
        self.assertEqual([t["name"] for t in agents], [t[0] for t in self.plugin.AGENT_TOOLS])
        self.assertEqual([t["name"] for t in debug], [t[0] for t in self.plugin.DEBUG_TOOLS])
        for tool in notes:
            with self.subTest(tool=tool["name"]):
                self.assertEqual(tool["toolset"], "notes")
                self.assertIs(tool["check_fn"], self.plugin._has_notes_store)
                self.assertTrue(tool["schema"]["description"])
                self.assertEqual(tool["schema"]["parameters"]["type"], "object")
                for name in tool["schema"]["parameters"]["required"]:
                    self.assertIn(name, tool["schema"]["parameters"]["properties"])
        for tool in agents:
            with self.subTest(tool=tool["name"]):
                self.assertEqual(tool["toolset"], "alice_agents")
                self.assertIs(tool["check_fn"], self.plugin._is_agent_maker)
        for tool in debug:
            with self.subTest(tool=tool["name"]):
                self.assertEqual(tool["toolset"], "alice_debug")
                self.assertIs(tool["check_fn"], self.plugin._always)

    def test_the_manifest_declares_the_tools_it_provides(self):
        import yaml

        manifest = yaml.safe_load((PLUGIN_INIT.parent / "plugin.yaml").read_text(encoding="utf-8"))
        self.assertEqual(
            sorted(manifest["provides_tools"]),
            sorted(
                [t[0] for t in self.plugin.NOTE_TOOLS]
                + [t[0] for t in self.plugin.AGENT_TOOLS]
                + [t[0] for t in self.plugin.DEBUG_TOOLS]
                + [t[0] for t in self.plugin.CALENDAR_TOOLS]
                + [t[0] for t in self.plugin.WATCH_TOOLS]
                + [t[0] for t in self.plugin.DOCUMENT_TOOLS]
            ),
        )

    def test_each_handler_passes_its_arguments_through(self):
        """The registered handler is what the registry calls: ``handler(args)``."""
        registered = {}

        class Ctx:
            def register_hook(self, *a, **k):
                pass

            def register_system_prompt_section(self, *a, **k):
                pass

            def register_tool(self, **kw):
                registered[kw["name"]] = kw["handler"]

        self.plugin.register(Ctx())
        added = json.loads(registered["note_add"]({"text": "por el handler"}))
        self.assertTrue(added["ok"])
        found = json.loads(registered["note_search"]({"query": "handler"}))
        self.assertEqual([h["text"] for h in found["hits"]], ["por el handler"])


if __name__ == "__main__":
    unittest.main()
