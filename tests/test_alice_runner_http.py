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
import subprocess
import sys
import unittest
import urllib.error
import urllib.request

from alice_secure_runner.core import AliceRunner, FictionalHTTPSAdapter
from alice_secure_runner.http_service import FixturePrincipal, RunnerHTTPS

import test_alice_secure_runner as shop_tests


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


if __name__ == "__main__":
    unittest.main()
