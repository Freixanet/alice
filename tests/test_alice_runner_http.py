"""End-to-end HTTPS trust boundary for a fictional hosted Alice worker.

Two separate TLS listeners bind *only* loopback with disposable certificates.
This does not establish cloud multi-tenancy, process sandbox or real-browser
isolation. No real merchants, credentials, payments, network egress or Hermes.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import ssl
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from alice_secure_runner.core import AliceRunner, FictionalHTTPSAdapter, _canonical
from alice_secure_runner.device_registry import RevocableP256DeviceConsent
from alice_secure_runner.http_service import FixturePrincipal, RunnerHTTPS

import test_alice_secure_runner as shop_tests
from test_h021_device_registry import _keypair, _sign


class RunnerHTTPSBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shop_tests.RunnerHTTPSContractTests.setUpClass()
        cls.shared = shop_tests.RunnerHTTPSContractTests

    @classmethod
    def tearDownClass(cls):
        cls.shared.tearDownClass()

    def setUp(self):
        self.store = self.shared.store
        with self.store._lock:
            self.store.carts.clear()
            self.store.orders.clear()
            self.store.submit_attempts = 0
            self.store.price_override = None
            self.store.fail_next_submit = False
            self.store.fail_next_quote = False
        self.device_key = secrets.token_bytes(32)
        self.runner_token = secrets.token_urlsafe(40)
        self.human_token = secrets.token_urlsafe(40)
        self.other_tenant_token = secrets.token_urlsafe(40)
        self.other_human_token = secrets.token_urlsafe(40)
        self.other_session_token = secrets.token_urlsafe(40)
        self.other_session_human_token = secrets.token_urlsafe(40)
        self.runner = AliceRunner(FictionalHTTPSAdapter(
            origin=self.shared.shop.url, ca_file=self.shared.cert, merchant_token=self.shared.shop_secret),
            approval_key=self.device_key)
        self.host = RunnerHTTPS(self.runner, principals={
            self.runner_token: FixturePrincipal("coordinator", "user-A", "paired"),
            self.human_token: FixturePrincipal("human", "user-A", "paired"),
            self.other_tenant_token: FixturePrincipal("coordinator", "user-B", "paired"),
            self.other_human_token: FixturePrincipal("human", "user-B", "paired"),
            self.other_session_token: FixturePrincipal("coordinator", "user-A", "other-session"),
            self.other_session_human_token: FixturePrincipal("human", "user-A", "other-session"),
        }, cert_file=self.shared.cert, key_file=self.shared.key)
        self.host.__enter__()
        self.ctx = ssl.create_default_context(cafile=self.shared.cert)

    def tearDown(self):
        self.host.__exit__(None, None, None)

    def request(self, endpoint, body, *, token=None):
        req = urllib.request.Request(
            self.host.url + endpoint,
            data=json.dumps(body).encode(), method="POST",
            headers={"Authorization": "Bearer " + (self.runner_token if token is None else token),
                     "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, context=self.ctx, timeout=3) as response:
            return json.loads(response.read())

    def test_https_lost_create_response_is_idempotent_and_principal_scoped(self):
        request_id = secrets.token_urlsafe(24)
        original = {"recipient": "Fictional delivery", "create_request_id": request_id}
        first = self.request("/v1/jobs", original)
        # A lost response sends the SAME request, never a new job/effect.
        self.assertEqual(self.request("/v1/jobs", original), first)
        self.assertEqual(self.request("/v1/resume", {"job_id": first["job_id"]})["status"],
                         "researching")
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/v1/jobs", {**original, "recipient": "Changed destination"})
        self.assertEqual(error.exception.code, 403)
        second_tenant = self.request("/v1/jobs", original, token=self.other_tenant_token)
        self.assertNotEqual(first["job_id"], second_tenant["job_id"])
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/v1/jobs", {"recipient": "Fictional delivery",
                                       "create_request_id": "short"})
        self.assertEqual(error.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_https_real_coordinator_to_runner_full_fake_purchase(self):
        start = self.request("/v1/jobs", {"tenant": "user-A", "session": "paired", "recipient": "Fake shipping"})
        jid = start["job_id"]
        actions = [
            {"action": "search", "query": "keyboard"},
            {"action": "read_product", "sku": "FAKE-ALICE-1"},
            {"action": "select_product", "sku": "FAKE-ALICE-1"},
            {"action": "add_to_cart", "quantity": 1},
            {"action": "prepare_checkout"},
        ]
        last = start
        for action in actions:
            last = self.request("/v1/propose", {"job_id": jid, "tenant": "user-A", "session": "paired",
                                                "proposal": {**action, "epoch": last["epoch"]}})
        self.assertEqual(last["checkout"]["amount_minor"], 2499)
        self.assertEqual(last["status"], "awaiting_approval")
        chall = self.request("/v1/challenge", {"job_id": jid, "tenant": "user-A", "session": "paired"})
        sig = hmac.new(self.device_key, json.dumps(chall, sort_keys=True, separators=(",", ":")).encode(),
                       hashlib.sha256).hexdigest()
        self.assertEqual(self.request("/v1/approve", {"job_id": jid, "tenant": "user-A", "session": "paired",
                                                      "signature": sig})["status"], "approved")
        result = self.request("/v1/commit", {"job_id": jid, "tenant": "user-A", "session": "paired"})
        self.assertEqual(result["status"], "confirmed_simulated")
        self.assertEqual(self.store.submit_attempts, 1)
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/commit", {"job_id": jid, "tenant": "user-A", "session": "paired"})
        self.assertEqual(err.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 1)

    def test_unprivileged_hermes_standin_no_runner_token_or_cdp(self):
        for endpoint in ("/v1/jobs", "/v1/resume", "/v1/propose", "/v1/challenge", "/v1/approve", "/v1/commit",
                         "/v1/human-handoff", "/v1/human-reissue", "/v1/human-finish"):
            with self.subTest(endpoint=endpoint), self.assertRaises(urllib.error.HTTPError) as err:
                self.request(endpoint, {}, token="the-Hermes-agent-has-no-capability")
            self.assertEqual(err.exception.code, 401)

        # A separate unprivileged *test* process, analogous to a Hermes shell
        # with no Alice backend token, can reach HTTPS but cannot call ASR.
        code = ("import json,ssl,sys,urllib.request,urllib.error; "
                "q=urllib.request.Request(sys.argv[1]+'/v1/commit',data=b'{}',method='POST'); "
                "s=ssl.create_default_context(cafile=sys.argv[2]); "
                "\ntry: urllib.request.urlopen(q,context=s,timeout=2); print('UNEXPECTED')"
                "\nexcept urllib.error.HTTPError as e: print('DENIED:'+str(e.code))")
        child = subprocess.run([sys.executable, "-c", code, self.host.url, self.shared.cert],
                               capture_output=True, text=True, timeout=5,
                               env={"PATH": os.environ.get("PATH", "")}, check=True)
        self.assertEqual(child.stdout.strip(), "DENIED:401")
        self.assertEqual(self.store.submit_attempts, 0)
        # No browser debugging URL or secret retrieval endpoint is even declared.
        for endpoint in ("/cdp", "/v1/browser", "/v1/credentials", "/v1/terminal"):
            with self.subTest(endpoint=endpoint), self.assertRaises(urllib.error.HTTPError) as err:
                self.request(endpoint, {}, token="the-Hermes-agent-has-no-capability")
            self.assertEqual(err.exception.code, 401)

    def test_authenticated_but_forbidden_effect_and_wrong_job_identity(self):
        start = self.request("/v1/jobs", {"tenant": "user-A", "session": "paired", "recipient": "Fake shipping"})
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/propose", {"job_id": start["job_id"], "tenant": "user-A", "session": "paired",
                                         "proposal": {"action": "browser_cdp", "method": "Runtime.evaluate", "epoch": 0}})
        self.assertEqual(err.exception.code, 403)
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/propose", {"job_id": start["job_id"], "tenant": "user-B", "session": "paired",
                                         "proposal": {"action": "search", "query": "keyboard", "epoch": 0}})
        self.assertEqual(err.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_human_completion_requires_separate_capability_and_one_use_handle(self):
        start = self.request("/v1/jobs", {"tenant": "user-A", "session": "paired", "recipient": "Fake shipping"})
        handoff = self.request("/v1/human-handoff", {"job_id": start["job_id"],
                                                      "tenant": "user-A", "session": "paired"})
        body = {"job_id": start["job_id"], "tenant": "user-A", "human_handle": handoff["human_handle"]}
        for wrong in (None, self.runner_token, "the-Hermes-agent-has-no-capability"):
            with self.subTest(wrong=wrong), self.assertRaises(urllib.error.HTTPError) as err:
                self.request("/v1/human-finish", body, token=wrong)
            self.assertEqual(err.exception.code, 401)
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/human-finish", {**body, "human_handle": "wrong"}, token=self.human_token)
        self.assertEqual(err.exception.code, 403)
        done = self.request("/v1/human-finish", body, token=self.human_token)
        self.assertEqual(done["payment_claim"], "NOT_VERIFIED")
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/human-finish", body, token=self.human_token)
        self.assertEqual(err.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_human_handoff_lost_http_response_reissues_handle_without_agent_resume(self):
        start = self.request("/v1/jobs", {"tenant": "user-A", "session": "paired", "recipient": "Fake shipping"})
        identity = {"job_id": start["job_id"], "tenant": "user-A", "session": "paired"}
        lost = self.request("/v1/human-handoff", identity)
        # Duplicate backend requests cannot invalidate the delivered link.
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/human-handoff", identity)
        self.assertEqual(err.exception.code, 403)
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/human-reissue", identity)
        self.assertEqual(err.exception.code, 401)
        # A separate human-side recovery action rotates the lost handle.
        recovered = self.request("/v1/human-reissue", identity, token=self.human_token)
        self.assertNotEqual(lost["human_handle"], recovered["human_handle"])
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/human-finish", {"job_id": start["job_id"], "tenant": "user-A",
                                                    "human_handle": lost["human_handle"]}, token=self.human_token)
        self.assertEqual(err.exception.code, 403)
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/propose", {**identity, "proposal": {"action": "stop", "epoch": 2}})
        self.assertEqual(err.exception.code, 403)
        done = self.request("/v1/human-finish", {"job_id": start["job_id"], "tenant": "user-A",
                                                  "human_handle": recovered["human_handle"]}, token=self.human_token)
        self.assertEqual(done["payment_claim"], "NOT_VERIFIED")
        self.assertEqual(self.store.submit_attempts, 0)

    def test_backend_and_human_capabilities_cannot_be_shared(self):
        with self.assertRaises(ValueError):
            RunnerHTTPS(self.runner, principals={self.runner_token: FixturePrincipal("coordinator", "user-A", "paired")},
                        cert_file=self.shared.cert, key_file=self.shared.key)
        with self.assertRaises(ValueError):
            RunnerHTTPS(self.runner, principals={
                self.runner_token: FixturePrincipal("coordinator", "user-A", "paired"),
                self.human_token: FixturePrincipal("human", "user-B", "paired")},
                cert_file=self.shared.cert, key_file=self.shared.key)
        with self.assertRaises(ValueError):
            RunnerHTTPS(self.runner, principals={
                "short": FixturePrincipal("coordinator", "user-A", "paired"),
                self.human_token: FixturePrincipal("human", "user-A", "paired")},
                cert_file=self.shared.cert, key_file=self.shared.key)

    def test_cross_tenant_principal_binding_blocks_claimed_identity_and_human_reissue(self):
        start = self.request("/v1/jobs", {"tenant": "user-A", "session": "paired", "recipient": "Fictional delivery"})
        jid = start["job_id"]
        # Valid bearer for B must not gain A's authority by supplying A's
        # tenant/session, even though it knows A's job ID and A's session name.
        attempts = (
            ("/v1/resume", {"job_id": jid, "tenant": "user-A", "session": "paired"}, self.other_tenant_token, 403),
            ("/v1/resume", {"job_id": jid, "tenant": "user-B", "session": "paired"}, self.other_tenant_token, 403),
            ("/v1/propose", {"job_id": jid, "tenant": "user-A", "session": "paired",
                              "proposal": {"action": "search", "query": "keyboard", "epoch": 0}}, self.other_tenant_token, 403),
            ("/v1/challenge", {"job_id": jid, "tenant": "user-A", "session": "paired"}, self.other_tenant_token, 403),
            ("/v1/human-handoff", {"job_id": jid, "tenant": "user-A", "session": "paired"}, self.other_tenant_token, 403),
            ("/v1/resume", {"job_id": jid, "tenant": "user-A", "session": "paired"}, self.other_session_token, 403),
        )
        for endpoint, body, token, code in attempts:
            with self.subTest(endpoint=endpoint, token=token[:5]), self.assertRaises(urllib.error.HTTPError) as err:
                self.request(endpoint, body, token=token)
            self.assertEqual(err.exception.code, code)

        handoff = self.request("/v1/human-handoff", {"job_id": jid, "tenant": "user-A", "session": "paired"})
        human_payload = {"job_id": jid, "tenant": "user-A", "session": "paired",
                         "human_handle": handoff["human_handle"]}
        for endpoint in ("/v1/human-reissue", "/v1/human-finish"):
            for body in (human_payload, {**human_payload, "tenant": "user-B"}):
                with self.subTest(endpoint=endpoint, tenant=body["tenant"]), self.assertRaises(urllib.error.HTTPError) as err:
                    self.request(endpoint, body, token=self.other_human_token)
                self.assertEqual(err.exception.code, 403)
        # Even a correct human handle cannot be used by the wrong principal.
        self.assertEqual(self.request("/v1/human-finish", human_payload, token=self.human_token)["payment_claim"],
                         "NOT_VERIFIED")
        self.assertEqual(self.store.submit_attempts, 0)

    def test_principal_identity_is_not_inferred_from_json_job_creation(self):
        # Omitted identity is supplied from authenticated token; false claims
        # fail closed before creating another tenant's job.
        own = self.request("/v1/jobs", {"recipient": "Fictional recipient"}, token=self.other_tenant_token)
        self.assertEqual(self.request("/v1/resume", {"job_id": own["job_id"]},
                                      token=self.other_tenant_token)["job_id"], own["job_id"])
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/jobs", {"tenant": "user-A", "session": "paired", "recipient": "Fake"},
                         token=self.other_tenant_token)
        self.assertEqual(err.exception.code, 403)

    def test_resume_endpoint_returns_epoch_but_never_human_handle(self):
        start = self.request("/v1/jobs", {"tenant": "user-A", "session": "paired", "recipient": "Fake shipping"})
        identity = {"job_id": start["job_id"], "tenant": "user-A", "session": "paired"}
        advanced = self.request("/v1/propose", {**identity,
                                                 "proposal": {"action": "search", "query": "keyboard", "epoch": 0}})
        observed = self.request("/v1/resume", identity)
        self.assertEqual(observed["epoch"], advanced["epoch"])
        self.assertEqual(observed["products"], [{"sku": "FAKE-ALICE-1"}])
        with self.assertRaises(urllib.error.HTTPError) as err:
            self.request("/v1/resume", {**identity, "session": "another-session"})
        self.assertEqual(err.exception.code, 403)
        handoff = self.request("/v1/human-handoff", identity)
        observed = self.request("/v1/resume", identity)
        self.assertEqual(observed["status"], "human_only")
        self.assertNotIn("human_handle", observed)
        self.assertNotIn(handoff["human_handle"], str(observed))

    def test_human_status_is_read_only_and_principal_scoped(self):
        start = self.request("/v1/jobs", {"recipient": "Fake shipping"})
        identity = {"job_id": start["job_id"]}
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/v1/human-status", identity)
        self.assertEqual(error.exception.code, 401)  # coordinator cannot impersonate human
        for token in (self.other_human_token, self.other_session_human_token,
                      "the-Hermes-agent-has-no-capability"):
            with self.subTest(token=token[:4]), self.assertRaises(urllib.error.HTTPError) as error:
                self.request("/v1/human-status", identity, token=token)
            self.assertIn(error.exception.code, (401, 403))
        pending = self.request("/v1/human-status", identity, token=self.human_token)
        self.assertEqual(pending["status"], "researching")
        self.assertEqual(pending["payment_environment"], "fictional_only")
        self.assertFalse(pending["can_submit_payment"])
        self.assertNotIn("fictional_receipt", pending)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_idle_tls_peer_cannot_block_authenticated_requests(self):
        """Slow handshake stays in bounded worker, never the accept loop."""
        idle = socket.create_connection(("127.0.0.1", self.host.server.server_port), timeout=2)
        completed = threading.Event()
        errors: list[Exception] = []
        def normal_request():
            try:
                response = self.request("/v1/jobs", {"recipient": "Fictional recipient"})
                assert response["status"] == "researching"
                completed.set()
            except Exception as exc:
                errors.append(exc)
        requester = threading.Thread(target=normal_request, daemon=True)
        try:
            requester.start()
            self.assertTrue(completed.wait(timeout=3),
                            "idle TLS handshake blocked unrelated valid request")
        finally:
            idle.close()
            requester.join(timeout=5)
        self.assertFalse(requester.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(self.store.submit_attempts, 0)

    def test_human_cancel_is_scoped_durable_and_blocks_legacy_proposals(self):
        created = self.request("/v1/jobs", {"recipient": "Fictional delivery"})
        jid = created["job_id"]
        identity = {"job_id": jid}
        for token in (self.runner_token, self.other_human_token, self.other_session_human_token):
            with self.subTest(token=token[:5]), self.assertRaises(urllib.error.HTTPError) as error:
                self.request("/v1/human-cancel", identity, token=token)
            self.assertIn(error.exception.code, (401, 403))
        cancelled = self.request("/v1/human-cancel", identity, token=self.human_token)
        self.assertEqual(cancelled["status"], "stopped")
        self.assertTrue(cancelled["browser_cleanup_verified"])
        self.assertEqual(self.request("/v1/human-cancel", identity,
                                      token=self.human_token)["status"], "stopped")
        self.assertEqual(self.request("/v1/human-status", identity,
                                      token=self.human_token)["status"], "stopped")
        for path, body in (("/v1/propose", {"proposal": {"action": "search", "query": "keyboard", "epoch": 0}}),
                           ("/v1/human-handoff", {}),
                           ("/v1/commit", {})):
            with self.subTest(path=path), self.assertRaises(urllib.error.HTTPError) as error:
                self.request(path, {**identity, **body})
            self.assertEqual(error.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_cancel_approved_exact_checkout_invalidates_signature_without_dispatch(self):
        start = self.request("/v1/jobs", {"recipient": "Fictional delivery"})
        jid, last = start["job_id"], start
        for action in ({"action": "search", "query": "keyboard"},
                       {"action": "select_product", "sku": "FAKE-ALICE-1"},
                       {"action": "add_to_cart", "quantity": 1},
                       {"action": "prepare_checkout"}):
            last = self.request("/v1/propose", {"job_id": jid,
                "proposal": {**action, "epoch": last["epoch"]}})
        signed = hmac.new(self.device_key, _canonical(last["approval_challenge"]),
                          hashlib.sha256).hexdigest()
        self.assertEqual(self.request("/v1/human-approve", {"job_id": jid,
            "signature": signed}, token=self.human_token)["status"], "approved")
        self.assertEqual(self.request("/v1/human-cancel", {"job_id": jid},
            token=self.human_token)["status"], "stopped")
        row = self.runner._AliceRunner__db.execute(
            "SELECT status FROM authorizations WHERE checkout_id=?",
            (last["checkout"]["checkout_id"],)).fetchone()
        self.assertEqual(row, ("stopped",))
        for path, token, body in (("/v1/commit", self.runner_token, {}),
                                  ("/v1/human-approve", self.human_token, {"signature": signed}),
                                  ("/v1/human-handoff", self.runner_token, {})):
            with self.subTest(path=path), self.assertRaises(urllib.error.HTTPError) as error:
                self.request(path, {"job_id": jid, **body}, token=token)
            self.assertEqual(error.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_human_cancel_does_not_erase_unknown_checkout_effect(self):
        start = self.request("/v1/jobs", {"recipient": "Fictional delivery"})
        jid, last = start["job_id"], start
        for action in ({"action": "search", "query": "keyboard"},
                       {"action": "select_product", "sku": "FAKE-ALICE-1"},
                       {"action": "add_to_cart", "quantity": 1},
                       {"action": "prepare_checkout"}):
            last = self.request("/v1/propose", {"job_id": jid,
                "proposal": {**action, "epoch": last["epoch"]}})
        signed = hmac.new(self.device_key, _canonical(last["approval_challenge"]),
                          hashlib.sha256).hexdigest()
        self.request("/v1/human-approve", {"job_id": jid,
            "signature": signed}, token=self.human_token)
        self.store.fail_next_submit = True
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/v1/commit", {"job_id": jid})
        self.assertEqual(error.exception.code, 409)
        attempts = self.store.submit_attempts
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/v1/human-cancel", {"job_id": jid}, token=self.human_token)
        self.assertEqual(error.exception.code, 409)
        self.assertEqual(self.request("/v1/human-status", {"job_id": jid},
                                      token=self.human_token)["status"], "unknown")
        self.assertEqual(self.store.submit_attempts, attempts)

    def test_cancelled_exact_checkout_survives_sqlite_restart(self):
        with tempfile.TemporaryDirectory(prefix="alice-cancel-restart-") as folder:
            path = Path(folder) / "runner.sqlite3"
            def construct():
                return AliceRunner(FictionalHTTPSAdapter(
                    origin=self.shared.shop.url, ca_file=self.shared.cert,
                    merchant_token=self.shared.shop_secret), approval_key=self.device_key,
                    ledger_path=path)
            runner = construct()
            created = runner.new_job("user-A", "paired", "Fictional delivery")
            jid = created["job_id"]
            last = created
            for action in ({"action": "search", "query": "keyboard"},
                           {"action": "select_product", "sku": "FAKE-ALICE-1"},
                           {"action": "add_to_cart", "quantity": 1},
                           {"action": "prepare_checkout"}):
                last = runner.propose(jid, tenant="user-A", session="paired",
                    proposal={**action, "epoch": last["epoch"]})
            self.assertEqual(runner.human_cancel(jid, tenant="user-A",
                session="paired")["status"], "stopped")
            runner.close()
            reopened = construct()
            try:
                self.assertEqual(reopened.human_status(jid, tenant="user-A",
                    session="paired")["status"], "stopped")
                self.assertEqual(reopened.human_cancel(jid, tenant="user-A",
                    session="paired")["status"], "stopped")
                self.assertEqual(reopened._AliceRunner__db.execute(
                    "SELECT status FROM authorizations WHERE checkout_id=?",
                    (last["checkout"]["checkout_id"],)).fetchone(), ("stopped",))
                self.assertEqual(self.store.submit_attempts, 0)
            finally:
                reopened.close()

    def test_human_status_only_confirms_matching_durable_fictional_receipt(self):
        start = self.request("/v1/jobs", {"recipient": "Fake shipping"})
        jid = start["job_id"]
        last = start
        for action in ({"action": "search", "query": "keyboard"},
                       {"action": "select_product", "sku": "FAKE-ALICE-1"},
                       {"action": "add_to_cart", "quantity": 1},
                       {"action": "prepare_checkout"}):
            last = self.request("/v1/propose", {"job_id": jid,
                "proposal": {**action, "epoch": last["epoch"]}})
        challenge = self.request("/v1/challenge", {"job_id": jid})
        before = self.request("/v1/human-status", {"job_id": jid}, token=self.human_token)
        self.assertEqual(before["status"], "awaiting_approval")
        self.assertEqual(before["checkout"], last["checkout"])
        self.assertNotIn("fictional_receipt", before)
        signature = hmac.new(self.device_key, json.dumps(challenge, sort_keys=True,
            separators=(",", ":")).encode(), hashlib.sha256).hexdigest()
        self.request("/v1/approve", {"job_id": jid, "signature": signature})
        self.request("/v1/commit", {"job_id": jid})
        confirmed = self.request("/v1/human-status", {"job_id": jid}, token=self.human_token)
        self.assertEqual(confirmed["status"], "confirmed")
        self.assertEqual(confirmed["fictional_receipt"]["amount_minor"], 2499)
        self.assertEqual(self.store.submit_attempts, 1)
        # The client must not display a confirmed merchant receipt merely
        # because ASR's own ledger says 'confirmed'. Independent receipt loss
        # or conflict fails closed, with no automatic second POST attempt.
        with self.store._lock:
            original = self.store.orders.pop(last["checkout"]["checkout_id"])
        missing = self.request("/v1/human-status", {"job_id": jid}, token=self.human_token)
        self.assertEqual(missing["status"], "unknown")
        self.assertNotIn("fictional_receipt", missing)
        self.assertEqual(self.store.submit_attempts, 1)
        with self.store._lock:
            self.store.orders[last["checkout"]["checkout_id"]] = original
        restored = self.request("/v1/human-status", {"job_id": jid}, token=self.human_token)
        self.assertEqual(restored["status"], "confirmed")
        # Simulate a mismatched/corrupted authorization ledger; never infer
        # confirmation from cached UI or a runner status flag alone.
        self.runner._AliceRunner__db.execute("UPDATE authorizations SET digest='invalid' WHERE checkout_id=?",
             (last["checkout"]["checkout_id"],))
        conflicting = self.request("/v1/human-status", {"job_id": jid}, token=self.human_token)
        self.assertEqual(conflicting["status"], "unknown")
        self.assertNotIn("fictional_receipt", conflicting)
        self.assertEqual(self.store.submit_attempts, 1)

    def test_slow_receipt_get_cannot_block_other_tenant_or_confirm_changed_ledger(self):
        created = self.request("/v1/jobs", {"recipient": "Fictional delivery"})
        jid, last = created["job_id"], created
        for action in ({"action": "search", "query": "keyboard"},
                       {"action": "select_product", "sku": "FAKE-ALICE-1"},
                       {"action": "add_to_cart", "quantity": 1},
                       {"action": "prepare_checkout"}):
            last = self.request("/v1/propose", {"job_id": jid,
                "proposal": {**action, "epoch": last["epoch"]}})
        signature = hmac.new(self.device_key, _canonical(last["approval_challenge"]),
                             hashlib.sha256).hexdigest()
        self.request("/v1/human-approve", {"job_id": jid,
            "signature": signature}, token=self.human_token)
        self.request("/v1/commit", {"job_id": jid})
        adapter = self.runner._AliceRunner__adapter
        real_lookup = adapter.lookup_order
        lookup_started, release_lookup, created_other = (
            threading.Event(), threading.Event(), threading.Event())
        result: list[dict] = []
        errors: list[Exception] = []

        def blocked_lookup(checkout_id):
            lookup_started.set()
            if not release_lookup.wait(timeout=5):
                raise TimeoutError("synthetic slow merchant")
            return real_lookup(checkout_id)

        def slow_status():
            try:
                result.append(self.request("/v1/human-status", {"job_id": jid},
                                           token=self.human_token))
            except Exception as exc:
                errors.append(exc)

        def unrelated_job():
            try:
                self.request("/v1/jobs", {"recipient": "Unrelated fictional delivery"},
                             token=self.other_tenant_token)
                created_other.set()
            except Exception as exc:
                errors.append(exc)

        adapter.lookup_order = blocked_lookup
        first = threading.Thread(target=slow_status, daemon=True)
        second = threading.Thread(target=unrelated_job, daemon=True)
        try:
            first.start()
            self.assertTrue(lookup_started.wait(timeout=3), "merchant GET did not start")
            second.start()
            self.assertTrue(created_other.wait(timeout=3),
                            "a slow merchant GET blocked a different tenant")
            # Simulate another trusted ledger writer during outbound GET. The
            # old response must not attest to the now-conflicting record.
            with self.runner._AliceRunner__lock:
                self.runner._AliceRunner__db.execute(
                    "UPDATE authorizations SET order_id='changed-after-read' WHERE checkout_id=?",
                    (last["checkout"]["checkout_id"],))
        finally:
            release_lookup.set()
            first.join(timeout=5)
            second.join(timeout=5)
            adapter.lookup_order = real_lookup
        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["status"], "unknown")
        self.assertNotIn("fictional_receipt", result[0])
        self.assertEqual(self.store.submit_attempts, 1)

    def test_separate_human_credential_approves_exact_fictional_checkout_without_dispatch(self):
        created = self.request("/v1/jobs", {"recipient": "Fictional recipient"})
        jid = created["job_id"]
        last = created
        for action in ({"action": "search", "query": "keyboard"},
                       {"action": "select_product", "sku": "FAKE-ALICE-1"},
                       {"action": "add_to_cart", "quantity": 1},
                       {"action": "prepare_checkout"}):
            last = self.request("/v1/propose", {"job_id": jid,
                "proposal": {**action, "epoch": last["epoch"]}})
        human = self.request("/v1/human-status", {"job_id": jid}, token=self.human_token)
        self.assertEqual(human["checkout"], last["checkout"])
        self.assertEqual(human["approval_challenge"], last["approval_challenge"])
        signature = hmac.new(self.device_key, json.dumps(human["approval_challenge"],
            sort_keys=True, separators=(",", ":")).encode(), hashlib.sha256).hexdigest()
        for token in (self.runner_token, self.other_human_token):
            with self.subTest(token=token[:4]), self.assertRaises(urllib.error.HTTPError) as error:
                self.request("/v1/human-approve", {"job_id": jid, "signature": signature}, token=token)
            self.assertIn(error.exception.code, (401, 403))
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/v1/human-approve", {"job_id": jid, "signature": "wrong"}, token=self.human_token)
        self.assertEqual(error.exception.code, 403)
        self.assertEqual(self.request("/v1/human-approve", {"job_id": jid,
            "signature": signature}, token=self.human_token)["status"], "approved")
        self.assertEqual(self.store.submit_attempts, 0)
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/v1/human-approve", {"job_id": jid,
                "signature": signature}, token=self.human_token)
        self.assertEqual(error.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_human_https_p256_enrolled_key_revocation_blocks_effect(self):
        """Fixture human bearer + enrolled P-256, not a real iOS IdP or biometric."""
        with tempfile.TemporaryDirectory(prefix="alice-human-p256-http-") as folder:
            base = Path(folder)
            private, pem = _keypair(base, "software-only-device")
            registry = RevocableP256DeviceConsent(base / "registry.sqlite3")
            self.addCleanup(registry.close)
            registry.enroll(tenant="user-A", session="paired", account="alice-fixture",
                            installation="software-fixture", public_pem=pem,
                            expires_at=int(time.time()) + 3600)
            runner = AliceRunner(FictionalHTTPSAdapter(
                origin=self.shared.shop.url, ca_file=self.shared.cert,
                merchant_token=self.shared.shop_secret), approval_verifier=registry)
            self.addCleanup(runner.close)
            with RunnerHTTPS(runner, principals={
                self.runner_token: FixturePrincipal("coordinator", "user-A", "paired"),
                self.human_token: FixturePrincipal("human", "user-A", "paired")},
                cert_file=self.shared.cert, key_file=self.shared.key) as host:
                def post(route, body, token):
                    request = urllib.request.Request(host.url + route,
                        data=json.dumps(body).encode(), method="POST",
                        headers={"Authorization": "Bearer " + token,
                                 "Content-Type": "application/json"})
                    with urllib.request.urlopen(request, context=self.ctx, timeout=3) as response:
                        return json.load(response)

                created = post("/v1/jobs", {"recipient": "fictional recipient"}, self.runner_token)
                jid, last = created["job_id"], created
                for action in ({"action": "search", "query": "keyboard"},
                               {"action": "select_product", "sku": "FAKE-ALICE-1"},
                               {"action": "add_to_cart", "quantity": 1},
                               {"action": "prepare_checkout"}):
                    last = post("/v1/propose", {"job_id": jid,
                        "proposal": {**action, "epoch": last["epoch"]}}, self.runner_token)
                status = post("/v1/human-status", {"job_id": jid}, self.human_token)
                self.assertEqual(status["approval_challenge"], last["approval_challenge"])
                signature = _sign(private, _canonical(status["approval_challenge"]), base)
                with self.assertRaises(urllib.error.HTTPError) as wrong:
                    post("/v1/human-approve", {"job_id": jid, "signature": signature},
                         self.runner_token)
                self.assertEqual(wrong.exception.code, 401)
                approved = post("/v1/human-approve", {"job_id": jid,
                    "signature": signature}, self.human_token)
                self.assertEqual(approved["status"], "approved")
                self.assertEqual(self.store.submit_attempts, 0)
                registry.revoke(tenant="user-A", session="paired", account="alice-fixture",
                                expected_version=1)
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    post("/v1/commit", {"job_id": jid}, self.runner_token)
                self.assertEqual(denied.exception.code, 403)
                self.assertEqual(self.store.submit_attempts, 0)

    def test_https_device_enrollment_is_exact_account_bound_and_one_use(self):
        """Synthetic Alice-account fixture only; NOT real iOS attestation/IdP."""
        with tempfile.TemporaryDirectory(prefix="alice-https-device-proof-") as folder:
            base = Path(folder)
            first, public = _keypair(base, "first")
            attacker, _ = _keypair(base, "attacker")
            second, next_public = _keypair(base, "second")
            registry = RevocableP256DeviceConsent(base / "devices.sqlite3")
            self.addCleanup(registry.close)
            runner = AliceRunner(FictionalHTTPSAdapter(
                origin=self.shared.shop.url, ca_file=self.shared.cert,
                merchant_token=self.shared.shop_secret), approval_verifier=registry)
            self.addCleanup(runner.close)
            coordinator = self.runner_token
            human = self.human_token
            others = self.other_human_token
            with self.assertRaises(ValueError):
                RunnerHTTPS(self.runner, principals={
                    coordinator: FixturePrincipal("coordinator", "user-A", "paired"),
                    human: FixturePrincipal("human", "user-A", "paired", "alice-account", "phone-A"),
                }, cert_file=self.shared.cert, key_file=self.shared.key,
                    device_registry=registry)  # different runner verifier
            with RunnerHTTPS(runner, principals={
                coordinator: FixturePrincipal("coordinator", "user-A", "paired"),
                human: FixturePrincipal("human", "user-A", "paired", "alice-account", "phone-A"),
                self.other_tenant_token: FixturePrincipal("coordinator", "user-B", "paired"),
                others: FixturePrincipal("human", "user-B", "paired", "other-account", "phone-B"),
            }, cert_file=self.shared.cert, key_file=self.shared.key,
                device_registry=registry) as host:
                def post(route, body, token=human):
                    request = urllib.request.Request(host.url + route,
                        data=json.dumps(body).encode(), method="POST",
                        headers={"Authorization": "Bearer " + token,
                                 "Content-Type": "application/json"})
                    with urllib.request.urlopen(request, context=self.ctx, timeout=3) as response:
                        return json.load(response)
                begin = "/v1/human-enrollment-begin"
                complete = "/v1/human-enrollment-complete"
                expires_at = int(time.time()) + 3600
                enrollment = {"public_pem": public, "key_expires_at": expires_at}
                for token, body in ((coordinator, enrollment),
                                    (others, {**enrollment, "tenant": "user-A"})):
                    with self.subTest(token=token[:5]), self.assertRaises(urllib.error.HTTPError) as error:
                        post(begin, body, token)
                    self.assertIn(error.exception.code, (401, 403))
                challenge = post(begin, enrollment)
                self.assertEqual(challenge["account"], "alice-account")
                self.assertEqual(challenge["installation"], "phone-A")
                proof = _sign(first, _canonical(challenge), base)
                wrong_proof = _sign(attacker, _canonical(challenge), base)
                for body, token in (({"challenge": challenge, "signature": wrong_proof}, human),
                                    ({"challenge": challenge, "signature": proof}, others),
                                    ({"challenge": {**challenge, "installation": "phone-B"},
                                      "signature": proof}, human)):
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        post(complete, body, token)
                    self.assertEqual(error.exception.code, 403)
                self.assertEqual(post(complete, {"challenge": challenge,
                    "signature": proof})["version"], 1)
                with self.assertRaises(urllib.error.HTTPError) as replay:
                    post(complete, {"challenge": challenge, "signature": proof})
                self.assertEqual(replay.exception.code, 403)
                self.assertTrue(registry.verify(tenant="user-A", session="paired",
                    challenge=b"exact-test", signature=_sign(first, b"exact-test", base)))
                next_challenge = post(begin, {"public_pem": next_public,
                    "key_expires_at": expires_at, "operation": "rotate", "expected_version": 1})
                next_signature = _sign(second, _canonical(next_challenge), base)
                self.assertEqual(post(complete, {"challenge": next_challenge,
                    "signature": next_signature})["version"], 2)
                self.assertFalse(registry.verify(tenant="user-A", session="paired",
                    challenge=b"exact-test", signature=_sign(first, b"exact-test", base)))
                self.assertEqual(post("/v1/human-enrollment-revoke",
                    {"expected_version": 2})["status"], "revoked_fixture_only")
                self.assertFalse(registry.verify(tenant="user-A", session="paired",
                    challenge=b"exact-test", signature=_sign(second, b"exact-test", base)))
                with self.assertRaises(urllib.error.HTTPError) as stale:
                    post("/v1/human-enrollment-revoke", {"expected_version": 2})
                self.assertEqual(stale.exception.code, 403)
                self.assertEqual(self.store.submit_attempts, 0)


if __name__ == "__main__":
    unittest.main()
