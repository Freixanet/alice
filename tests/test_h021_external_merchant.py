"""Actual independent-process HTTPS merchant / durable receipt recovery.

Disposable fictional credentials and loopback only. No Docker, cloud, payments,
personal Hermes or private browser profile are used in these tests.
"""
from __future__ import annotations

import hmac
import hashlib
import json
import os
import selectors
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path

from alice_secure_runner.core import AliceRunner, Denied, FictionalHTTPSAdapter, Indeterminate
from alice_secure_runner.coordinator import Coordinator, FictionalPlanner


MERCHANT_PROCESS = """
import os,time
from alice_secure_runner.fictional_shop import PersistentFictionalStore,FixtureHTTPS
s=PersistentFictionalStore(secret=os.environ['TEST_EFFECT'],browser_read_secret=os.environ['TEST_READ'],
                          ledger_path=os.environ['TEST_MERCHANT_DB'])
with FixtureHTTPS(s,os.environ['TEST_CERT'],os.environ['TEST_KEY']) as h:
 print(h.url,flush=True)
 while True: time.sleep(0.05)
"""


class ExternalMerchantRecovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="h021-external-merchant-")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.cert = str(self.dir / "localhost.pem")
        self.key = str(self.dir / "localhost.key")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                        "-nodes", "-sha256", "-days", "1",
                        "-keyout", self.key, "-out", self.cert,
                        "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       check=True, capture_output=True)
        self.effect = "independent-fictional-effect-secret-not-a-real-key-" + "A" * 20
        self.read = "fictional-browser-read-only-token-" + "B" * 28
        self.db = str(self.dir / "merchant.sqlite3")
        self.ledger = str(self.dir / "alice.sqlite3")
        self.device = b"fictional-device-not-real-approval" + b"X" * 16
        self.proc = None
        self.addCleanup(self.stop_merchant)
        self.start_merchant()

    def start_merchant(self):
        env = {**os.environ, "TEST_EFFECT": self.effect, "TEST_READ": self.read,
               "TEST_MERCHANT_DB": self.db, "TEST_CERT": self.cert,
               "TEST_KEY": self.key,
               "PYTHONPATH": str(Path(__file__).resolve().parents[1])}
        self.proc = subprocess.Popen([sys.executable, "-u", "-c", MERCHANT_PROCESS],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        deadline = time.monotonic() + 8
        collected = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(self.proc.stdout, selectors.EVENT_READ)
            while b"\n" not in collected and time.monotonic() < deadline:
                if self.proc.poll() is not None:
                    break
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                block = os.read(self.proc.stdout.fileno(), 2048)
                if not block:
                    break
                collected.extend(block)
                if len(collected) > 2048:
                    break
        url = bytes(collected).split(b"\n", 1)[0].decode(errors="replace").strip()
        if not url.startswith("https://localhost:"):
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait(timeout=5)
            error = self.proc.stderr.read(2048).decode(errors="replace")
            self.stop_merchant()
            self.fail("fictional merchant failed to start: " + error)
        self.adapter = FictionalHTTPSAdapter(origin=url, ca_file=self.cert, merchant_token=self.effect)

    def stop_merchant(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.kill()  # destructive process restart: persisted SQLite survives
            self.proc.wait(timeout=5)
        if self.proc is not None:
            self.proc.stdout.close()
            self.proc.stderr.close()
        self.proc = None

    def prepared(self):
        runner = AliceRunner(self.adapter, approval_key=self.device, ledger_path=self.ledger)
        flow = Coordinator(runner, tenant="fixture-tenant-A", session="paired-A",
                           recipient="FICTIONAL address", planner=FictionalPlanner())
        result = flow.run_to_approval()
        challenge = runner.challenge(flow.job_id, tenant="fixture-tenant-A", session="paired-A")
        consent = hmac.new(self.device, json.dumps(challenge, sort_keys=True, separators=(",", ":"),
                             ensure_ascii=False).encode(), hashlib.sha256).hexdigest()
        runner.approve(flow.job_id, tenant="fixture-tenant-A", session="paired-A", signature=consent)
        return runner, flow.job_id, result["checkout"]

    def test_receipt_survives_both_process_restarts_and_reconciles_unknown(self):
        runner, job, checkout = self.prepared()
        actual_submit = self.adapter.commit
        calls = []

        def lose_http_reply(**kwargs):
            calls.append(kwargs["idempotency_key"])
            actual_submit(**kwargs)  # independent merchant durably accepts order
            raise ConnectionResetError("fictional HTTP reply lost AFTER effect")

        self.adapter.commit = lose_http_reply
        with self.assertRaises(Indeterminate):
            runner.commit(job, tenant="fixture-tenant-A", session="paired-A")
        self.assertEqual(calls, [checkout["checkout_id"]])
        runner.close()  # ASR restart is independent of merchant's SQLite volume
        self.stop_merchant()  # merchant itself also dies abruptly
        self.start_merchant()
        reopened = AliceRunner(self.adapter, approval_key=self.device, ledger_path=self.ledger)
        try:
            with self.assertRaises(Denied):
                reopened.commit(job, tenant="fixture-tenant-A", session="paired-A")
            self.assertEqual(reopened.resume_job(job, tenant="fixture-tenant-A",
                                                 session="paired-A")["status"], "unknown")
            receipt = self.adapter.lookup_order(checkout["checkout_id"])
            self.assertEqual(receipt["checkout_id"], checkout["checkout_id"])
            result = reopened.reconcile_unknown(job, tenant="fixture-tenant-A", session="paired-A")
            self.assertEqual(result["reconciliation"], "merchant_receipt")
            self.assertEqual(result["status"], "confirmed_simulated")
            with self.assertRaises(Denied):
                reopened.reconcile_unknown(job, tenant="fixture-tenant-A", session="paired-A")
            with sqlite3.connect(self.db) as merchant:
                self.assertEqual(merchant.execute("SELECT COUNT(*) FROM orders").fetchone()[0], 1)
            with sqlite3.connect(self.ledger) as asr:
                self.assertEqual(asr.execute("SELECT status FROM authorizations").fetchone()[0], "confirmed")
        finally:
            reopened.close()

    def test_no_receipt_remains_unknown_without_checkout_retry(self):
        runner, job, checkout = self.prepared()
        self.adapter.commit = lambda **kw: (_ for _ in ()).throw(ConnectionResetError("before send"))
        try:
            with self.assertRaises(Indeterminate):
                runner.commit(job, tenant="fixture-tenant-A", session="paired-A")
            result = runner.reconcile_unknown(job, tenant="fixture-tenant-A", session="paired-A")
            self.assertEqual(result["status"], "unknown")
            self.assertIsNone(self.adapter.lookup_order(checkout["checkout_id"]))
            with self.assertRaises(Denied):
                runner.commit(job, tenant="fixture-tenant-A", session="paired-A")
        finally:
            runner.close()

    def test_unreachable_merchant_preserves_unknown_with_typed_reconciliation(self):
        runner, job, checkout = self.prepared()
        self.adapter.commit = lambda **kw: (_ for _ in ()).throw(ConnectionResetError("fictional"))
        try:
            with self.assertRaises(Indeterminate):
                runner.commit(job, tenant="fixture-tenant-A", session="paired-A")
            self.stop_merchant()
            result = runner.reconcile_unknown(job, tenant="fixture-tenant-A", session="paired-A")
            self.assertEqual(result["status"], "unknown")
            self.assertEqual(result["reconciliation"], "merchant_unavailable")
            with sqlite3.connect(self.ledger) as asr:
                self.assertEqual(asr.execute("SELECT status FROM authorizations").fetchone()[0], "unknown")
        finally:
            runner.close()

    def test_immutable_idempotency_rejects_changed_recipient_after_merchant_restart(self):
        cart = "fictional-cart-0001"
        self.adapter.cart(cart, "FAKE-ALICE-1", 2)
        original = self.adapter.quote(cart, "recipient-A")
        snapshot = {**original, "checkout_id": "same-checkout-id-0001"}
        first = self.adapter.commit(cart_id=cart, recipient="recipient-A",
                                    snapshot=snapshot, idempotency_key=snapshot["checkout_id"])
        self.stop_merchant()
        self.start_merchant()
        self.adapter.cart("fictional-cart-0002", "FAKE-ALICE-1", 2)
        second = self.adapter.quote("fictional-cart-0002", "recipient-B")
        changed = {**second, "checkout_id": snapshot["checkout_id"]}
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.adapter.commit(cart_id="fictional-cart-0002", recipient="recipient-B",
                                snapshot=changed, idempotency_key=snapshot["checkout_id"])
        self.assertEqual(raised.exception.code, 422)
        unchanged = self.adapter.lookup_order(snapshot["checkout_id"])
        self.assertEqual(unchanged, first)

    def test_browser_read_token_cannot_access_persistent_receipts(self):
        cart = "fictional-cart-readonly"
        self.adapter.cart(cart, "FAKE-ALICE-1", 1)
        quote = self.adapter.quote(cart, "recipient-A")
        receipt = self.adapter.commit(cart_id=cart, recipient="recipient-A",
                                      snapshot={**quote, "checkout_id": "readonly-test-checkout"},
                                      idempotency_key="readonly-test-checkout")
        browser_only = FictionalHTTPSAdapter(origin=self.adapter._base,
                                              ca_file=self.cert, merchant_token=self.read)
        with self.assertRaises(urllib.error.HTTPError) as raised:
            browser_only.lookup_order(receipt["checkout_id"])
        self.assertEqual(raised.exception.code, 403)

    def test_tax_shipping_and_discount_are_exact_checkout_consent(self):
        runner, job, checkout = self.prepared()
        self.assertEqual(checkout["subtotal_minor"], 4998)
        self.assertEqual(checkout["tax_minor"], 0)
        self.assertEqual(checkout["shipping_minor"], 0)
        self.assertEqual(checkout["discount_minor"], 0)
        # The same total does NOT authorize rearranging tax and shipping.
        self.adapter.quote = lambda *_: {
            "sku": checkout["sku"], "variant": checkout["variant"],
            "quantity": checkout["quantity"],
            "recipient": checkout["recipient"], "merchant_id": checkout["merchant_id"],
            "currency": checkout["currency"],
            "subtotal_minor": checkout["subtotal_minor"],
            "tax_minor": 20, "shipping_minor": 0, "discount_minor": 20,
            "amount_minor": checkout["amount_minor"]}
        try:
            with self.assertRaisesRegex(Denied, "itemization"):
                runner.commit(job, tenant="fixture-tenant-A", session="paired-A")
            with sqlite3.connect(self.db) as merchant:
                self.assertEqual(merchant.execute("SELECT COUNT(*) FROM orders").fetchone()[0], 0)
        finally:
            runner.close()

    def test_variant_selection_changes_price_and_is_bound_to_exact_consent(self):
        runner = AliceRunner(self.adapter, approval_key=self.device, ledger_path=self.ledger)
        try:
            job = runner.new_job("fixture-tenant-A", "paired-A", "fake delivery")["job_id"]
            epoch = 0
            for action in (
                {"action": "search", "query": "keyboard"},
                {"action": "select_product", "sku": "FAKE-ALICE-1"},
                {"action": "select_variant", "variant": "graphite"},
                {"action": "add_to_cart", "quantity": 2},
                {"action": "prepare_checkout"},
            ):
                result = runner.propose(job, tenant="fixture-tenant-A", session="paired-A",
                                        proposal={**action, "epoch": epoch})
                epoch = result["epoch"]
            checkout = result["checkout"]
            self.assertEqual(checkout["variant"], "graphite")
            self.assertEqual(checkout["subtotal_minor"], 5998)
            self.assertEqual(checkout["amount_minor"], 5998)
            challenge = runner.challenge(job, tenant="fixture-tenant-A", session="paired-A")
            signature = hmac.new(
                self.device,
                json.dumps(challenge, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False).encode(), hashlib.sha256).hexdigest()
            runner.approve(job, tenant="fixture-tenant-A", session="paired-A", signature=signature)
            done = runner.commit(job, tenant="fixture-tenant-A", session="paired-A")
            receipt = self.adapter.lookup_order(done["checkout_id"])
            self.assertEqual(receipt["variant"], "graphite")
            self.assertEqual(done["amount_minor"], 5998)
        finally:
            runner.close()


if __name__ == "__main__":
    unittest.main()
