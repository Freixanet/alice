"""The dashboard routes Alice uses for errands: list, approve or deny the checkout, answer, stop.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PLUGIN_API = Path(__file__).resolve().parents[1] / "dashboard" / "plugin_api.py"

CHECKOUT = {"merchant": "HSN", "site": "hsnstore.com", "items": [{"name": "Creatina 500 g", "qty": 1}],
            "total": "27,98 €", "card_label": "Visa ···4242"}


def load_plugin():
    spec = importlib.util.spec_from_file_location("hermes_dashboard_plugin_alice_errands_test", PLUGIN_API)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ErrandRoutesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        cls.api = load_plugin()
        app = FastAPI()
        app.include_router(cls.api.router, prefix=cls.api.PLUGIN_PREFIX)
        cls.client = TestClient(app)

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.errands = self.api._errands_module()
        self.resumed = []
        for patch in (
            mock.patch.object(self.api, "_hermes_root", return_value=self.home),
            mock.patch.object(self.errands, "launch", return_value=False),
            mock.patch.object(self.errands, "resume", side_effect=lambda h, i, m: self.resumed.append((i, m)) or True),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def url(self, path=""):
        return f"{self.api.PLUGIN_PREFIX}/errands{path}"

    def waiting(self):
        entry = self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure")
        self.errands.request_checkout(self.home, entry["id"], CHECKOUT)
        return self.errands.get(self.home, entry["id"])

    def test_the_list_hides_the_session_wiring(self):
        entry = self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure",
                                    origin_session="chat-1")
        body = self.client.get(self.url()).json()
        self.assertEqual([e["id"] for e in body["errands"]], [entry["id"]])
        self.assertNotIn("origin_session", body["errands"][0])
        self.assertEqual(self.client.get(self.url("/nope")).status_code, 404)

    def test_allow_approves_the_checkout_seen_and_resumes_the_errand(self):
        entry = self.waiting()
        checkout_id = entry["checkout"]["id"]
        answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                  json={"decision": "allow", "checkout_id": checkout_id})
        self.assertEqual(answer.status_code, 200)
        saved = self.errands.get(self.home, entry["id"])
        self.assertEqual(saved["checkout"]["status"], "approved")
        self.assertEqual(len(self.resumed), 1)
        self.assertTrue(self.resumed[0][1].startswith(self.errands.APPROVED_PREFIX))
        self.assertIn("27,98 €", self.resumed[0][1])
        # A second tap, or a stale card, changes nothing.
        again = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                 json={"decision": "allow", "checkout_id": checkout_id})
        self.assertEqual(again.status_code, 409)

    def test_an_approval_for_another_checkout_is_refused(self):
        entry = self.waiting()
        answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                  json={"decision": "allow", "checkout_id": "other"})
        self.assertEqual(answer.status_code, 409)
        self.assertEqual(self.errands.get(self.home, entry["id"])["checkout"]["status"], "pending")
        self.assertEqual(self.resumed, [])

    def test_deny_ends_it_without_resuming(self):
        entry = self.waiting()
        answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                  json={"decision": "deny", "checkout_id": entry["checkout"]["id"]})
        self.assertEqual(answer.json()["errand"]["status"], "denied")
        self.assertEqual(self.resumed, [])
        bad = self.client.post(self.url(f"/{entry['id']}/checkout"), json={"decision": "maybe", "checkout_id": "x"})
        self.assertEqual(bad.status_code, 400)

    def test_answers_resume_a_waiting_errand(self):
        entry = self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure")
        self.assertEqual(self.client.post(self.url(f"/{entry['id']}/answer"),
                                          json={"answers": {"size": "500 g"}}).status_code, 409)
        self.errands.ask(self.home, entry["id"], "Tamaño", [{"id": "size", "question": "¿Qué tamaño?"}])
        answer = self.client.post(self.url(f"/{entry['id']}/answer"), json={"answers": {"size": "500 g"}})
        self.assertEqual(answer.status_code, 200)
        self.assertEqual(self.resumed, [(entry["id"], "[respuesta:size] 500 g")])

    def test_stop_marks_it_stopped(self):
        entry = self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure")
        with mock.patch.object(self.errands, "_goal_manager"):
            body = self.client.post(self.url(f"/{entry['id']}/stop")).json()
        self.assertEqual(body["errand"]["status"], "stopped")


if __name__ == "__main__":
    unittest.main()
