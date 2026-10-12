"""Run: python3 -m unittest discover -s tests -p test_alice_secure_runner.py -v

TLS network is strictly the ephemeral loopback fictional merchant. No real
browser, money, account, hosted service, Hermes process or personal credentials.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest import mock
from pathlib import Path

from alice_secure_runner.coordinator import Coordinator, FictionalPlanner
from alice_secure_runner.core import AliceRunner, Denied, FictionalHTTPSAdapter, Indeterminate
from alice_secure_runner.fictional_shop import FictionalStore, FixtureHTTPS


def signed(challenge: dict, key: bytes) -> str:
    return hmac.new(key, json.dumps(challenge, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(),
                    hashlib.sha256).hexdigest()


class RunnerHTTPSContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="alice-secure-runner-https-")
        cls.cert = str(Path(cls.tmp.name) / "fictional.cert")
        cls.key = str(Path(cls.tmp.name) / "fictional.key")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                        "-nodes", "-days", "1", "-keyout", cls.key, "-out", cls.cert,
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=20)
        cls.shop_secret = secrets.token_urlsafe(40)
        cls.store = FictionalStore(secret=cls.shop_secret)
        cls.shop = FixtureHTTPS(cls.store, cls.cert, cls.key)
        cls.shop.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.shop.__exit__(None, None, None)
        cls.tmp.cleanup()

    def setUp(self):
        self.store.price_override = None
        self.store.fail_next_quote = False
        self.store.fail_next_submit = False
        self.store.certified_adapter = True
        with self.store._lock:
            self.store.carts.clear()
            self.store.orders.clear()
            self.store.submit_attempts = 0
        self.device_key = secrets.token_bytes(32)
        self.adapter = FictionalHTTPSAdapter(origin=self.shop.url, ca_file=self.cert, merchant_token=self.shop_secret)
        self.runner = AliceRunner(self.adapter, approval_key=self.device_key)
        self.client = Coordinator(self.runner, tenant="user-A", session="alice-paired-1",
                                  recipient="Fictional delivery", planner=FictionalPlanner())

    def ready(self):
        result = self.client.run_to_approval()
        self.assertEqual([event["proposed"]["action"] for event in self.client.events],
                         ["search", "read_product", "select_product", "add_to_cart", "prepare_checkout"])
        self.assertEqual(result["checkout"]["sku"], "FAKE-ALICE-1")
        self.assertEqual(result["checkout"]["quantity"], 2)
        self.assertEqual(result["checkout"]["amount_minor"], 4998)
        self.assertEqual(result["checkout"]["currency"], "EUR")
        return result

    def authorize(self):
        challenge = self.runner.challenge(self.client.job_id, tenant="user-A", session="alice-paired-1")
        return self.runner.approve(self.client.job_id, tenant="user-A", session="alice-paired-1",
                                   signature=signed(challenge, self.device_key))

    def test_full_https_flow_exact_authorized_single_synthetic_checkout(self):
        result = self.ready()
        self.assertEqual(self.store.submit_attempts, 0)
        self.assertEqual(result["status"], "awaiting_approval")
        self.authorize()
        receipt = self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1")
        self.assertEqual(receipt["status"], "confirmed_simulated")
        self.assertEqual(receipt["amount_minor"], 4998)
        self.assertEqual(self.store.submit_attempts, 1)
        self.assertEqual(len(self.store.orders), 1)
        with self.assertRaises(Denied):
            self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1")
        self.assertEqual(self.store.submit_attempts, 1)

    def test_missing_wrong_replayed_user_approval(self):
        self.ready()
        with self.assertRaises(Denied):
            self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1")
        with self.assertRaises(Denied):
            self.runner.approve(self.client.job_id, tenant="user-A", session="alice-paired-1", signature="forged")
        self.authorize()
        with self.assertRaises(Denied):
            self.authorize()
        self.assertEqual(self.store.submit_attempts, 0)

    def test_expired_challenge_denied_even_with_original_signature(self):
        self.ready()
        signature = signed(self.runner.challenge(self.client.job_id, tenant="user-A", session="alice-paired-1"),
                           self.device_key)
        with mock.patch("alice_secure_runner.core.time.time", return_value=time.time() + 600):
            with self.assertRaisesRegex(Denied, "expired"):
                self.runner.approve(self.client.job_id, tenant="user-A", session="alice-paired-1", signature=signature)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_simultaneous_commits_do_not_send_twice(self):
        self.ready()
        self.authorize()
        barrier = threading.Barrier(3)
        results = []
        def send():
            barrier.wait()
            try:
                results.append(self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1"))
            except Denied:
                results.append("denied")
        tasks = [threading.Thread(target=send) for _ in range(2)]
        for task in tasks: task.start()
        barrier.wait()
        for task in tasks: task.join(timeout=5)
        self.assertEqual(len(results), 2)
        self.assertEqual(sum(isinstance(r, dict) for r in results), 1)
        self.assertEqual(self.store.submit_attempts, 1)

    def test_changed_amount_fails_before_external_submit(self):
        self.ready()
        self.authorize()
        self.store.price_override = 2899
        with self.assertRaisesRegex(Denied, "amount changed"):
            self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1")
        self.assertEqual(self.store.submit_attempts, 0)

    def test_failure_after_dispatch_is_unknown_and_never_retried(self):
        self.ready()
        self.authorize()
        self.store.fail_next_submit = True
        with self.assertRaises(Indeterminate):
            self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1")
        with self.assertRaises(Denied):
            self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1")
        self.assertEqual(self.store.submit_attempts, 1)

    def test_network_failure_before_dispatch_is_not_treated_as_paid(self):
        self.ready()
        self.authorize()
        self.store.fail_next_quote = True
        with self.assertRaises(urllib.error.HTTPError):
            self.runner.commit(self.client.job_id, tenant="user-A", session="alice-paired-1")
        self.assertEqual(self.store.submit_attempts, 0)

    def test_model_cannot_execute_payment_or_scripts_cdp_http_terminal(self):
        first = self.client.step()
        epoch = first["epoch"]
        for name in ("checkout_commit", "pay", "browser_exec", "browser_cdp", "js", "shell", "http", "terminal"):
            with self.subTest(name=name), self.assertRaises(Denied):
                self.runner.propose(self.client.job_id, tenant="user-A", session="alice-paired-1",
                                    proposal={"action": name, "epoch": epoch})
        for extra in ({"action": "search", "query": "keyboard", "epoch": epoch, "url": "https://outside.example"},
                      {"action": "search", "query": "keyboard", "epoch": epoch, "script": "fetch('/commit')"},
                      {"action": "search", "query": "keyboard", "epoch": epoch - 1},
                      {"action": "search", "query": "keyboard", "epoch": True}):
            with self.assertRaises(Denied):
                self.runner.propose(self.client.job_id, tenant="user-A", session="alice-paired-1", proposal=extra)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_other_session_and_tenant_cannot_read_or_act(self):
        self.ready()
        for kwargs in ({"tenant": "user-B", "session": "alice-paired-1"},
                       {"tenant": "user-A", "session": "another-Hermes-session"}):
            with self.assertRaises(Denied):
                self.runner.challenge(self.client.job_id, **kwargs)
            with self.assertRaises(Denied):
                self.runner.propose(self.client.job_id, **kwargs,
                                    proposal={"action": "stop", "epoch": 5})
            with self.assertRaises(Denied):
                self.runner.commit(self.client.job_id, **kwargs)

    def test_human_only_handoff_is_exclusive_not_existing_checkout_button(self):
        self.ready()
        handoff = self.runner.human_handoff(self.client.job_id, tenant="user-A", session="alice-paired-1")
        self.assertEqual(handoff["status"], "awaiting_human_finalization")
        for cmd in ("search", "checkout_commit"):
            with self.assertRaises(Denied):
                self.runner.propose(self.client.job_id, tenant="user-A", session="alice-paired-1",
                                    proposal={"action": cmd, "epoch": 6, "query": "keyboard"})
        with self.assertRaises(Denied):
            self.runner.human_finalize(self.client.job_id, tenant="user-A", human_handle="forged")
        result = self.runner.human_finalize(self.client.job_id, tenant="user-A", human_handle=handoff["human_handle"])
        self.assertEqual(result["payment_claim"], "NOT_VERIFIED")
        with self.assertRaises(Denied):
            self.runner.human_finalize(self.client.job_id, tenant="user-A", human_handle=handoff["human_handle"])
        self.assertEqual(self.store.submit_attempts, 0)

    def test_failing_certificate_or_untrusted_origin_is_rejected(self):
        with self.assertRaises(Denied):
            FictionalHTTPSAdapter(origin="http://localhost:1221", ca_file=self.cert, merchant_token=self.shop_secret)
        with self.assertRaises(Denied):
            FictionalHTTPSAdapter(origin="https://shop.example", ca_file=self.cert, merchant_token=self.shop_secret)
        rogue = FictionalHTTPSAdapter(origin=self.shop.url, ca_file=self.cert, merchant_token="wrong-key")
        with self.assertRaises(urllib.error.HTTPError):
            rogue.search("keyboard")


if __name__ == "__main__":
    unittest.main()
