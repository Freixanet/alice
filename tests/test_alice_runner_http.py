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
from alice_secure_runner.http_service import RunnerHTTPS

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
        self.runner = AliceRunner(FictionalHTTPSAdapter(
            origin=self.shared.shop.url, ca_file=self.shared.cert, merchant_token=self.shared.shop_secret),
            approval_key=self.device_key)
        self.host = RunnerHTTPS(self.runner, coordinator_token=self.runner_token,
                                cert_file=self.shared.cert, key_file=self.shared.key)
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
        for endpoint in ("/v1/jobs", "/v1/propose", "/v1/challenge", "/v1/approve", "/v1/commit",
                         "/v1/human-handoff", "/v1/human-finish"):
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


if __name__ == "__main__":
    unittest.main()
