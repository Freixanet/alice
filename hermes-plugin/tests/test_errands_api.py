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
            mock.patch.object(self.errands, "_fetch", side_effect=OSError("offline")),
            mock.patch.object(self.errands, "resume", side_effect=lambda h, i, m, **kwargs: self.resumed.append((i, m)) or True),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def url(self, path=""):
        return f"{self.api.PLUGIN_PREFIX}/errands{path}"

    def waiting(self):
        entry = self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure")
        self.errands.request_checkout(self.home, entry["id"], CHECKOUT)
        return self.errands.get(self.home, entry["id"])

    def test_secure_request_is_recovered_with_only_public_metadata(self):
        entry = self.errands.create(self.home, "Compra creatina")
        pending = {"request_id":"srq-test", "kind":"vault.save_login", "origin":"https://example.com",
                   "site":"example.com", "errand_id":entry["id"], "profile":"default",
                   "context":"private-context", "target":"private-target"}
        self.errands.update(self.home,entry["id"],status="needs_login",secure_request=pending)
        # A new HTTP request after reconnect/restart reads the persisted request.
        response = self.client.get(self.url(f"/{entry['id']}/access"))
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.json()["request"]["request_id"],"srq-test")
        self.assertNotIn("private-context",response.text)
        self.assertNotIn("private-target",response.text)
        self.assertIn("no-store",response.headers["cache-control"])

    def test_malformed_secure_answers_never_echo_input(self):
        secret = "FAKE-only-sensitive-input"
        for body in ({"request_id":"x", "value":secret, "unexpected":secret},
                     {"request_id":"x", "value":secret * 1000},
                     {"request_id":"x", "value":secret, "account_action":secret}):
            response = self.client.post(self.url("/fictional/access"),json=body)
            self.assertEqual(response.status_code,400)
            self.assertNotIn(secret,response.text)

    def test_the_list_hides_the_session_wiring(self):
        entry = self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure",
                                    origin_session="chat-1")
        body = self.client.get(self.url()).json()
        self.assertEqual([e["id"] for e in body["errands"]], [entry["id"]])
        self.assertEqual(body["errands"][0]["origin_session"], "chat-1")
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

    def test_checkout_replaced_between_endpoint_check_and_decision_is_not_approved(self):
        entry = self.waiting()
        original = self.errands.decide_checkout
        replacement = {}

        def replace_then_decide(*args, **kwargs):
            self.errands.request_checkout(self.home, entry["id"], {**CHECKOUT, "total": "279,80 €"})
            replacement.update(self.errands.get(self.home, entry["id"])["checkout"])
            return original(*args, **kwargs)

        with mock.patch.object(self.errands, "decide_checkout", side_effect=replace_then_decide):
            answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                      json={"decision": "allow", "checkout_id": entry["checkout"]["id"]})
        self.assertEqual(answer.status_code, 409)
        saved = self.errands.get(self.home, entry["id"])["checkout"]
        self.assertNotEqual(saved["id"], entry["checkout"]["id"])
        self.assertEqual(saved, replacement)
        self.assertEqual(saved["status"], "pending")
        self.assertEqual(self.resumed, [])

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


    def test_the_icon_is_the_shops_own_logo(self):
        entry = self.errands.create(self.home, "Compra", title="iPhone", site="apple.com")
        seen = {}

        class Icons:
            def __init__(self, home):
                pass

            def get(self, name, hosts, urls):
                seen["name"] = name
                return (b"\x89PNG", "image/png")

        with mock.patch.object(self.api, "_connector_icons", return_value=mock.Mock(Icons=Icons)):
            answer = self.client.get(self.url(f"/{entry['id']}/icon"))
        self.assertEqual(answer.status_code, 200)
        self.assertEqual(seen["name"], "apple.com")
        bare = self.errands.create(self.home, "Compra", title="Algo")
        self.assertEqual(self.client.get(self.url(f"/{bare['id']}/icon")).status_code, 404)

    def test_a_card_left_ready_resumes_the_errand(self):
        entry = self.errands.create(self.home, "Compra", title="iPhone")
        self.assertEqual(self.client.post(self.url(f"/{entry['id']}/card"), json={"label": "Visa ···4242"}).status_code, 409)
        self.errands.request_card(self.home, entry["id"], "https://secure.apple.com/pay")
        answer = self.client.post(self.url(f"/{entry['id']}/card"), json={"label": "Visa ···4242"})
        self.assertEqual(answer.status_code, 200)
        self.assertIn("Visa ···4242", self.resumed[-1][1])
        self.assertIn("checkout_request", self.resumed[-1][1])

    def test_a_stale_checkout_is_prepared_again_not_approved(self):
        entry = self.waiting()
        checkout = entry["checkout"]
        self.errands.update(self.home, entry["id"], checkout={**checkout, "requested_at": 1.0})
        late = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                json={"decision": "allow", "checkout_id": checkout["id"]})
        self.assertEqual(late.status_code, 409)
        self.assertIn("caducado", late.json()["detail"])
        self.assertEqual(self.resumed, [])
        again = self.client.post(self.url(f"/{entry['id']}/refresh"))
        self.assertEqual(again.status_code, 200)
        self.assertIn("checkout_request", self.resumed[-1][1])
        self.assertEqual(self.client.post(self.url(f"/{entry['id']}/refresh")).status_code, 409)


    def test_response_and_wakeup_keep_the_decided_snapshot_after_replacement(self):
        entry = self.waiting()
        messages = []

        def replace_on_resume(home, errand_id, message, **kwargs):
            messages.append((message, kwargs["checkout"]))
            self.errands.request_checkout(home, errand_id, {**CHECKOUT, "total": "279,80 €"})
            return False

        with mock.patch.object(self.errands, "resume", side_effect=replace_on_resume):
            answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                      json={"decision": "allow", "checkout_id": entry["checkout"]["id"]})
        self.assertEqual(answer.status_code, 200)
        decided = answer.json()["errand"]["checkout"]
        self.assertEqual(decided["id"], entry["checkout"]["id"])
        self.assertEqual(decided["status"], "approved")
        self.assertEqual(messages, [(self.errands.approved_message(decided), decided)])
        self.assertEqual(self.errands.get(self.home, entry["id"])["checkout"]["status"], "pending")

    def test_stopped_between_endpoint_check_and_decision_is_not_resumed(self):
        entry = self.waiting()
        original = self.errands.decide_checkout

        def stop_then_decide(*args, **kwargs):
            self.errands.update(self.home, entry["id"], status="stopped")
            return original(*args, **kwargs)

        with mock.patch.object(self.errands, "decide_checkout", side_effect=stop_then_decide):
            answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                      json={"decision": "allow", "checkout_id": entry["checkout"]["id"]})
        self.assertEqual(answer.status_code, 409)
        self.assertEqual(self.resumed, [])
        self.assertEqual(self.errands.get(self.home, entry["id"])["status"], "stopped")

    def test_corrupt_archive_returns_safe_error_and_is_not_changed(self):
        entry = self.waiting()
        path = self.errands._path(self.home)
        for content in (b"{broken", b"{}", b"[null]", b"[{}]", b"\xff"):
            with self.subTest(content=content):
                path.write_bytes(content)
                answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                          json={"decision": "allow", "checkout_id": entry["checkout"]["id"]})
                self.assertEqual(answer.status_code, 503)
                self.assertEqual(path.read_bytes(), content)
                self.assertEqual(self.resumed, [])


    def test_failed_decision_persistence_returns_error_without_resuming(self):
        entry = self.waiting()
        path = self.errands._path(self.home)
        before = path.read_bytes()
        with mock.patch.object(self.errands.os, "replace", side_effect=OSError("synthetic disk failure")):
            answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                      json={"decision": "allow", "checkout_id": entry["checkout"]["id"]})
        self.assertEqual(answer.status_code, 503)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(self.resumed, [])


    def test_wakeup_failure_keeps_decision_and_exact_message_persisted(self):
        entry = self.waiting()
        with mock.patch.object(self.errands, "resume", side_effect=OSError("synthetic wakeup failure")):
            with self.assertRaises(OSError):
                self.client.post(self.url(f"/{entry['id']}/checkout"),
                                 json={"decision": "allow", "checkout_id": entry["checkout"]["id"]})
        saved = self.errands.get(self.home, entry["id"])
        self.assertEqual(saved["checkout"]["status"], "approved")
        self.assertEqual(saved["resume_message"], self.errands.approved_message(saved["checkout"]))
        again = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                 json={"decision": "allow", "checkout_id": entry["checkout"]["id"]})
        self.assertEqual(again.status_code, 409)
        self.assertEqual(self.resumed, [])


    def test_timestamp_less_legacy_checkout_can_be_refreshed_without_approval(self):
        entry = self.waiting()
        checkout = dict(entry["checkout"])
        checkout.pop("requested_at")
        self.errands.update(self.home, entry["id"], checkout=checkout)
        answer = self.client.post(self.url(f"/{entry['id']}/checkout"),
                                  json={"decision": "allow", "checkout_id": checkout["id"]})
        self.assertEqual(answer.status_code, 409)
        self.assertEqual(self.resumed, [])
        saved = self.errands.get(self.home, entry["id"])["checkout"]
        self.assertEqual(saved, {**checkout, "status": "expired"})
        refresh = self.client.post(self.url(f"/{entry['id']}/refresh"))
        self.assertEqual(refresh.status_code, 200)
        self.assertIn("checkout_request", self.resumed[-1][1])
        self.assertNotIn(self.errands.APPROVED_PREFIX, self.resumed[-1][1])


if __name__ == "__main__":
    unittest.main()
