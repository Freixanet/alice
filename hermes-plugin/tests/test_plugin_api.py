"""Alice plugin backend, run with the Hermes virtualenv:

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests

Hermes' helpers are replaced where a test would otherwise touch the real installation.
"""
import base64
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PLUGIN_API = Path(__file__).resolve().parents[1] / "dashboard" / "plugin_api.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("hermes_dashboard_plugin_alice_test", PLUGIN_API)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PluginAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        cls.api = load_plugin()
        app = FastAPI()
        app.include_router(cls.api.router, prefix=cls.api.PLUGIN_PREFIX)
        app.state.bound_port = 9119
        app.state.bound_host = "127.0.0.1"
        cls.client = TestClient(app)

    def setUp(self):
        self.api._reset_claim_state_for_tests()
        self.config = {"profile": "default", "gateway": {"url": "http://mac.tail.ts.net:8643", "key": "k"},
                       "dashboard": None}
        self.hermes_home = tempfile.TemporaryDirectory()
        self.addCleanup(self.hermes_home.cleanup)
        patches = [
            mock.patch.object(self.api, "_build_pairing_config",
                              mock.AsyncMock(return_value=(self.config, "default", "mac.tail.ts.net", "Alice"))),
            mock.patch.object(self.api, "_source_ip", return_value="100.100.1.2"),
            mock.patch.object(self.api, "_engine_home", return_value=Path(self.hermes_home.name)),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def mint(self):
        response = self.client.post("/api/plugins/alice/pairing/session")
        self.assertEqual(response.status_code, 200, response.text)
        link = response.json()["payload"]
        encoded = link.split("p=", 1)[1]
        offer = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        return link, offer

    def claim(self, token, body=None, **headers):
        return self.client.post("/api/plugins/alice/pairing/claim",
                                headers={"Authorization": f"Bearer {token}", **headers},
                                json=body if body is not None else {"token": token, "device_name": "iPhone"})

    def test_the_offer_is_alices_v1_link_pointing_at_the_plugins_claim_route(self):
        link, offer = self.mint()
        self.assertTrue(link.startswith("alice://pair?v=1&p="))
        self.assertEqual(list(offer), ["c", "t", "e", "pr"])
        self.assertEqual(offer["c"], "http://mac.tail.ts.net:9119/api/plugins/alice/pairing/claim")
        self.assertEqual(offer["pr"], "default")

    def test_a_code_is_claimed_exactly_once(self):
        _, offer = self.mint()
        first = self.claim(offer["t"])
        self.assertEqual(first.status_code, 200)
        self.assertEqual(first.json(), self.config)
        self.assertEqual(first.headers["cache-control"], "no-store, max-age=0")
        again = self.claim(offer["t"])
        self.assertEqual(again.status_code, 410)

    def test_the_token_seam_recognises_live_and_used_codes_only(self):
        provider = self.api._provider_class()()
        _, offer = self.mint()
        self.assertIsNotNone(provider.verify_token(token=offer["t"]))
        self.claim(offer["t"])
        self.assertIsNotNone(provider.verify_token(token=offer["t"]), "a used code still answers 410, not 401")
        self.assertIsNone(provider.verify_token(token="never-minted"))
        self.assertIsNone(provider.verify_token(token=""))

    def test_an_expired_code_is_gone_for_the_seam_and_the_route(self):
        provider = self.api._provider_class()()
        _, offer = self.mint()
        with self.api._lock:
            self.api._offers[offer["t"]]["expires_at"] = 0
        self.assertIsNone(provider.verify_token(token=offer["t"]))
        self.assertEqual(self.claim(offer["t"]).status_code, 404)

    def test_a_body_token_must_name_the_bearers_code(self):
        _, offer = self.mint()
        response = self.claim(offer["t"], body={"token": "someone-else", "device_name": "iPhone"})
        self.assertEqual(response.status_code, 404)
        self.assertEqual(self.claim(offer["t"], body={"device_name": "iPhone"}).status_code, 200)

    def test_claims_come_only_from_loopback_or_the_tailnet_and_never_through_a_proxy(self):
        _, offer = self.mint()
        with mock.patch.object(self.api, "_source_ip", return_value="192.168.1.20"):
            self.assertEqual(self.claim(offer["t"]).status_code, 403)
        self.assertEqual(self.claim(offer["t"], **{"X-Forwarded-For": "100.100.1.2"}).status_code, 403)
        self.assertTrue(self.api._origin_allowed("127.0.0.1"))
        self.assertTrue(self.api._origin_allowed("100.67.213.42"))
        self.assertFalse(self.api._origin_allowed("8.8.8.8"))

    def test_a_new_code_replaces_the_previous_one(self):
        _, first = self.mint()
        _, second = self.mint()
        self.assertEqual(self.claim(first["t"]).status_code, 404)
        self.assertEqual(self.claim(second["t"]).status_code, 200)

    def test_memory_is_read_and_edited_for_a_known_profile_only(self):
        class Store:
            def __init__(self):
                self.entries = {"memory": ["uno"], "user": []}

            def _entries_for(self, target):
                return self.entries[target]

            def target_enabled(self, target):
                return True

            def _char_limit(self, target):
                return 2200

            def add(self, target, content):
                self.entries[target].append(content)
                return {"success": True}

        store = Store()
        profile = type("P", (), {"name": "radar-ia"})()
        fake_memory_tool = type(sys)("tools.memory_tool")
        fake_memory_tool.load_on_disk_store = lambda: store
        fake_store_module = type(sys)("tools.memory_tool_store")
        fake_store_module.ENTRY_DELIMITER = "\n§\n"
        with mock.patch.dict(sys.modules, {"tools.memory_tool": fake_memory_tool,
                                           "tools.memory_tool_store": fake_store_module}), \
                mock.patch.object(self.api, "_list_profiles", return_value=[profile]), \
                mock.patch.object(self.api, "_profile_scope", mock.MagicMock()), \
                mock.patch.object(self.api, "_load_config", return_value={}):
            read = self.client.get("/api/plugins/alice/memory", params={"profile": "radar-ia"})
            self.assertEqual(read.status_code, 200, read.text)
            self.assertEqual(read.json()["targets"][1]["entries"], ["uno"])
            added = self.client.post("/api/plugins/alice/memory",
                                     json={"profile": "radar-ia", "target": "memory", "action": "add", "content": "dos"})
            self.assertEqual(added.status_code, 200, added.text)
            self.assertEqual(added.json()["targets"][1]["entries"], ["uno", "dos"])
            self.assertEqual(self.client.get("/api/plugins/alice/memory", params={"profile": "nope"}).status_code, 404)
            bad = self.client.post("/api/plugins/alice/memory",
                                   json={"profile": "radar-ia", "target": "secrets", "action": "add"})
            self.assertEqual(bad.status_code, 400)

    def notes_profile(self, root):
        """A profile whose workspace holds a notes store with a stand-in for its ``inbox.py``."""
        import tempfile
        import textwrap

        home = Path(root) / "profiles" / "inbox"
        store = home / "workspace" / "inbox-store"
        store.mkdir(parents=True)
        (store / "inbox.py").write_text(textwrap.dedent("""
            import json, os, sys
            from pathlib import Path
            text = sys.stdin.read()
            if sys.argv[1:] != ["add", "--stdin"] or not text.strip():
                print(json.dumps({"ok": False, "error": "texto vacío"})); sys.exit(1)
            entry = {"schema": 1, "id": "n3", "ts": "2026-09-15T10:00:00+02:00", "text": text,
                     "urls": [], "heuristic_types": ["tarea"], "bytes": len(text.encode())}
            with (Path(os.environ["INBOX_STORE"]) / "entries.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\\n")
            print(json.dumps({"ok": True, "id": "n3", "ts": entry["ts"], "types": ["tarea"]}))
        """), encoding="utf-8")
        return type("P", (), {"name": "inbox", "path": home})(), store

    def test_without_a_notes_store_notes_are_unavailable_and_nothing_is_written(self):
        import tempfile

        with tempfile.TemporaryDirectory() as root:
            other = type("P", (), {"name": "default", "path": Path(root)})()
            with mock.patch.object(self.api, "_list_profiles", return_value=[other]):
                read = self.client.get("/api/plugins/alice/notes")
                self.assertEqual(read.status_code, 200, read.text)
                self.assertEqual(read.json(), {"available": False, "notes": [], "total": 0})
                self.assertEqual(self.client.post("/api/plugins/alice/notes", json={"text": "hola"}).status_code, 404)

    def test_the_chosen_notes_store_is_remembered_when_profiles_are_listed_in_another_order(self):
        with tempfile.TemporaryDirectory() as root:
            def profile(name):
                home = Path(root) / name
                store = home / "workspace" / "inbox-store"
                store.mkdir(parents=True)
                (store / "inbox.py").write_text("print(1)\n", encoding="utf-8")
                return type("P", (), {"name": name, "path": home})()
            alpha, beta = profile("alpha"), profile("beta")
            with mock.patch.object(self.api, "_list_profiles", return_value=[alpha, beta]):
                first = self.api._notes_store()
            self.assertEqual(first[0], "alpha")
            with mock.patch.object(self.api, "_list_profiles", return_value=[beta, alpha]):
                again = self.api._notes_store()
            self.assertEqual(again[0], "alpha")
            saved = json.loads((Path(self.hermes_home.name) / ".alice" / "notes_store.json").read_text())
            self.assertEqual(saved["profile"], "alpha")

    def test_inbox_is_preferred_until_a_remembered_store_is_gone(self):
        with tempfile.TemporaryDirectory() as root:
            def profile(name):
                home = Path(root) / name
                store = home / "workspace" / "inbox-store"
                store.mkdir(parents=True)
                (store / "inbox.py").write_text("print(1)\n", encoding="utf-8")
                return type("P", (), {"name": name, "path": home})()
            inbox, other = profile("inbox"), profile("other")
            with mock.patch.object(self.api, "_list_profiles", return_value=[other, inbox]):
                self.assertEqual(self.api._notes_store()[0], "inbox")
            with mock.patch.object(self.api, "_list_profiles", return_value=[other]):
                self.assertEqual(self.api._notes_store()[0], "other")
            saved = json.loads((Path(self.hermes_home.name) / ".alice" / "notes_store.json").read_text())
            self.assertEqual(saved["profile"], "other")

    def test_notes_are_listed_newest_first_with_the_agents_reading_of_them(self):
        import tempfile

        with tempfile.TemporaryDirectory() as root:
            profile, store = self.notes_profile(root)
            (store / "entries.jsonl").write_text(
                json.dumps({"id": "n1", "ts": "2026-09-14T09:00:00+02:00", "text": "Idea: notas en Alice",
                            "heuristic_types": ["idea"]}) + "\n"
                + "not json\n"
                + json.dumps({"id": "n2", "ts": "2026-09-14T10:00:00+02:00", "text": "Llamar al banco",
                              "heuristic_types": ["tarea"]}) + "\n", encoding="utf-8")
            (store / "enrichment.jsonl").write_text(
                json.dumps({"id": "n1", "types": ["idea"], "topics": ["viejo"], "processed": False}) + "\n"
                + json.dumps({"id": "n1", "types": ["idea", "posible_proyecto"], "topics": ["alice"],
                              "summary": "Notas", "processed": True}) + "\n", encoding="utf-8")
            with mock.patch.object(self.api, "_list_profiles", return_value=[profile]):
                read = self.client.get("/api/plugins/alice/notes").json()
        self.assertTrue(read["available"])
        self.assertEqual(read["profile"], "inbox")
        self.assertEqual([note["id"] for note in read["notes"]], ["n2", "n1"])
        self.assertEqual(read["notes"][0]["types"], ["tarea"])
        self.assertFalse(read["notes"][0]["processed"])
        self.assertEqual(read["notes"][1]["types"], ["idea", "posible_proyecto"])
        self.assertEqual(read["notes"][1]["topics"], ["alice"])
        self.assertTrue(read["notes"][1]["processed"])

    def test_a_note_is_saved_by_the_stores_own_add_exactly_as_written(self):
        import tempfile

        with tempfile.TemporaryDirectory() as root:
            profile, store = self.notes_profile(root)
            text = "Comprar pan; $(rm -rf ~) no es un comando\n"
            with mock.patch.object(self.api, "_list_profiles", return_value=[profile]):
                saved = self.client.post("/api/plugins/alice/notes", json={"text": text})
                self.assertEqual(saved.status_code, 200, saved.text)
                self.assertEqual(saved.json()["note"]["id"], "n3")
                self.assertEqual(saved.json()["note"]["text"], text)
                self.assertEqual(self.client.post("/api/plugins/alice/notes", json={"text": "   "}).status_code, 400)
                self.assertEqual(self.client.post("/api/plugins/alice/notes", json={"text": "x", "profile": "y"}).status_code, 422)
            stored = [json.loads(line) for line in (store / "entries.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual([row["text"] for row in stored], [text])

    def test_an_edited_note_is_rewritten_in_place_and_sorted_again(self):
        import base64
        import tempfile

        with tempfile.TemporaryDirectory() as root:
            profile, store = self.notes_profile(root)
            (store / "entries.jsonl").write_text(
                json.dumps({"id": "n1", "ts": "2026-09-14T09:00:00+02:00", "text": "uno"}) + "\n"
                + json.dumps({"id": "n2", "ts": "2026-09-14T10:00:00+02:00", "text": "dos"}) + "\n",
                encoding="utf-8")
            (store / "enrichment.jsonl").write_text(
                json.dumps({"id": "n2", "summary": "Dos", "processed": True}) + "\n", encoding="utf-8")
            rich = base64.b64encode(b"{\\rtf1 dos editado}").decode()
            with mock.patch.object(self.api, "_list_profiles", return_value=[profile]):
                edited = self.client.put("/api/plugins/alice/notes/n2",
                                         json={"text": "dos editado https://x.io", "rich": rich})
                self.assertEqual(edited.status_code, 200, edited.text)
                note = edited.json()["note"]
                self.assertEqual(note["text"], "dos editado https://x.io")
                self.assertEqual(note["rich"], rich)
                self.assertFalse(note["processed"])
                self.assertEqual(note["summary"], "Dos")
                self.assertEqual(self.client.put("/api/plugins/alice/notes/nope", json={"text": "x"}).status_code, 404)
                self.assertEqual(self.client.put("/api/plugins/alice/notes/n1", json={"text": " "}).status_code, 400)
                self.assertEqual(
                    self.client.put("/api/plugins/alice/notes/n1", json={"text": "x", "rich": "%%"}).status_code, 400)
                read = self.client.get("/api/plugins/alice/notes").json()
            stored = [json.loads(line) for line in (store / "entries.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual([row["id"] for row in stored], ["n1", "n2"])
        self.assertEqual(stored[0]["text"], "uno")
        self.assertEqual(stored[1]["urls"], ["https://x.io"])
        self.assertEqual([note["id"] for note in read["notes"]], ["n2", "n1"])
        self.assertFalse(read["notes"][0]["processed"])

    def test_a_deleted_note_goes_with_its_reading_and_relations(self):
        import tempfile

        with tempfile.TemporaryDirectory() as root:
            profile, store = self.notes_profile(root)
            (store / "entries.jsonl").write_text(
                json.dumps({"id": "n1", "text": "uno"}) + "\n" + json.dumps({"id": "n2", "text": "dos"}) + "\n",
                encoding="utf-8")
            (store / "enrichment.jsonl").write_text(
                json.dumps({"id": "n1", "processed": True}) + "\n" + json.dumps({"id": "n2", "processed": True}) + "\n",
                encoding="utf-8")
            (store / "relations.jsonl").write_text(
                json.dumps({"id": "r1", "a": "n1", "b": "n2", "type": "similar"}) + "\n", encoding="utf-8")
            with mock.patch.object(self.api, "_list_profiles", return_value=[profile]):
                deleted = self.client.delete("/api/plugins/alice/notes/n2")
                self.assertEqual(deleted.status_code, 200, deleted.text)
                self.assertEqual(self.client.delete("/api/plugins/alice/notes/n2").status_code, 404)
                read = self.client.get("/api/plugins/alice/notes").json()
            entries = (store / "entries.jsonl").read_text(encoding="utf-8")
            enrichment = (store / "enrichment.jsonl").read_text(encoding="utf-8")
            relations = (store / "relations.jsonl").read_text(encoding="utf-8")
        self.assertEqual([note["id"] for note in read["notes"]], ["n1"])
        self.assertNotIn("n2", entries)
        self.assertNotIn("n2", enrichment)
        self.assertEqual(relations, "")

    def test_notes_come_with_their_folders_and_tags(self):
        import tempfile

        with tempfile.TemporaryDirectory() as root:
            profile, store = self.notes_profile(root)
            (store / "folders.json").write_text(json.dumps(
                {"folders": [{"id": "salud-1", "name": "Salud"}]}), encoding="utf-8")
            (store / "entries.jsonl").write_text(
                json.dumps({"id": "n1", "text": "magnesio"}) + "\n"
                + json.dumps({"id": "n2", "text": "viaje"}) + "\n", encoding="utf-8")
            (store / "enrichment.jsonl").write_text(
                json.dumps({"id": "n1", "folder": "salud-1", "tags": ["suplementos"]}) + "\n"
                + json.dumps({"id": "n2", "folder": "gone-9", "tags": []}) + "\n", encoding="utf-8")
            with mock.patch.object(self.api, "_list_profiles", return_value=[profile]):
                read = self.client.get("/api/plugins/alice/notes").json()
        self.assertEqual(read["folders"], [{"id": "salud-1", "name": "Salud"}])
        notes = {note["id"]: note for note in read["notes"]}
        self.assertEqual(notes["n1"]["folder"], "salud-1")
        self.assertEqual(notes["n1"]["tags"], ["suplementos"])
        self.assertIsNone(notes["n2"]["folder"], "a deleted folder's notes are Quick Notes")

    def test_agent_create_and_rename_go_through_the_engine(self):
        import os
        import tempfile

        soul = (
            "# Radar\n\nWatch the news.\n\n## Examples\n\n"
            "Person: What happened?\nYou: **This.** Two sentences.\n\n"
            "Person: Invent it.\nYou: No.\n"
        )
        fake = Path(__file__).resolve().parents[2] / "hermes-agents" / "forja" / "tests" / "fake_hermes.py"
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            wrapper = home / "hermes"
            wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{fake}" "$@"\n', encoding="utf-8")
            wrapper.chmod(0o755)
            old = {k: os.environ.get(k) for k in ("HERMES_HOME", "HERMES_BIN", "ALICE_FAKE_AUTH")}
            os.environ["HERMES_HOME"] = str(home)
            os.environ["HERMES_BIN"] = str(wrapper)
            os.environ["ALICE_FAKE_AUTH"] = "1"
            try:
                with mock.patch.object(self.api, "_engine_home", return_value=home):
                    created = self.client.post("/api/plugins/alice/agents", json={
                        "title": "Resumen de Mercados",
                        "description": "Mornings.",
                        "soul": soul,
                        "tools": ["web"],
                        "model": "kept-model",
                        "provider": "kept-provider",
                        "source": "form",
                    })
                    self.assertEqual(created.status_code, 200, created.text)
                    payload = created.json()
                    self.assertEqual(payload["status"], "completed", payload)
                    self.assertEqual(payload["profile_id"], "resumen-de-mercados")
                    renamed = self.client.post("/api/plugins/alice/agents/rename", json={
                        "from": "resumen-de-mercados",
                        "to": "Radar IA",
                    })
                    self.assertEqual(renamed.status_code, 200, renamed.text)
                    body = renamed.json()
                    self.assertEqual(body["to_id"], "radar-ia", body)
                    self.assertEqual(body["status"], "failed", body)
                    self.assertIn("registry_home", (body.get("error") or "").lower())
                    self.assertTrue((home / "profiles" / "resumen-de-mercados").is_dir())
                    self.assertFalse((home / "profiles" / "radar-ia").exists())
                    traversal = self.client.get("/api/plugins/alice/agents/jobs/../etc/passwd")
                    self.assertIn(traversal.status_code, {400, 404, 422})
                    encoded = self.client.get("/api/plugins/alice/agents/jobs/%2e%2e%2fetc%2fpasswd")
                    self.assertIn(encoded.status_code, {400, 404, 422})
                    missing = self.client.get("/api/plugins/alice/agents/jobs/job-missing")
                    self.assertEqual(missing.status_code, 404)
                    rejected = self.client.post("/api/plugins/alice/agents", json={
                        "title": "Intruso",
                        "description": "No.",
                        "soul": soul,
                        "job_id": "../etc/passwd",
                    })
                    self.assertEqual(rejected.status_code, 200, rejected.text)
                    self.assertEqual(rejected.json()["status"], "failed")
                    self.assertIn("job_id", (rejected.json().get("error") or "").lower())
                    self.assertFalse((home / "etc").exists())
                    self.assertFalse((home / "profiles" / "intruso").exists())
            finally:
                for key, value in old.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value


if __name__ == "__main__":
    unittest.main(verbosity=2)
