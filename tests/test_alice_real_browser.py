"""REAL ephemeral Chromium, fictional loopback TLS, NEVER a real purchase.

Opt-in: ALICE_TEST_PLAYWRIGHT_MODULE=<runner-only Playwright package dir>
        ALICE_TEST_CHROME_PATH=<installed chrome executable> (if needed).
The browser is controlled only over private Alice subprocess stdio. Browser
contexts DO NOT establish OS isolation from a hostile same-user Hermes shell.
"""

import os
import secrets
import json
import ssl
import unittest
import urllib.error
import urllib.request

from alice_secure_runner.browser_fixture import BrowserFixtureReadAdapter
from alice_secure_runner.coordinator import Coordinator, FictionalPlanner
from alice_secure_runner.core import AliceRunner, Denied, Indeterminate
from alice_secure_runner.fictional_shop import FictionalStore, FixtureHTTPS

import test_alice_secure_runner as fixture


@unittest.skipUnless(os.getenv("ALICE_TEST_PLAYWRIGHT_MODULE"),
                     "Requires disposable real Chromium in Alice runner fixture environment")
class RealChromiumFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture.RunnerHTTPSContractTests.setUpClass()
        cls.shop_fixture = fixture.RunnerHTTPSContractTests
        cls.adapter = BrowserFixtureReadAdapter(
            origin=cls.shop_fixture.shop.url, ca_file=cls.shop_fixture.cert,
            merchant_token=cls.shop_fixture.shop_secret,
            browser_read_token=cls.shop_fixture.store.browser_read_secret,
            playwright_module=os.environ["ALICE_TEST_PLAYWRIGHT_MODULE"],
            chrome_path=os.getenv("ALICE_TEST_CHROME_PATH"))

    @classmethod
    def tearDownClass(cls):
        try:
            cls.adapter.close()
        finally:
            cls.shop_fixture.tearDownClass()

    def setUp(self):
        self.store = self.shop_fixture.store
        with self.store._lock:
            self.store.carts.clear()
            self.store.orders.clear()
            self.store.submit_attempts = 0
            self.store.fail_next_quote = False
            self.store.fail_next_submit = False
            self.store.price_override = None
            self.store.certified_adapter = True
            self.store.redirect_browser_to = None
        self.key = secrets.token_bytes(32)
        self.runner = AliceRunner(self.adapter, approval_key=self.key)

    def client(self, tenant="tenant-A", session="paired-A"):
        return Coordinator(self.runner, tenant=tenant, session=session,
                           recipient="Synthetic delivery", planner=FictionalPlanner())

    def test_real_browser_typed_flow_approval_and_once_only_fake_order(self):
        client = self.client()
        blocked_before = self.adapter.fixture_stats()["blocked_checkout_posts"]
        checkout = client.run_to_approval()
        self.assertEqual(checkout["checkout"]["amount_minor"], 4998)
        self.assertGreater(self.adapter.fixture_stats()["blocked_checkout_posts"], blocked_before)
        # The real page attempted a same-origin POST. The browser request gate
        # prevented it before the merchant's /commit handler was entered.
        self.assertEqual(self.store.submit_attempts, 0)
        challenge = self.runner.challenge(client.job_id, tenant="tenant-A", session="paired-A")
        self.runner.approve(client.job_id, tenant="tenant-A", session="paired-A",
                            signature=fixture.signed(challenge, self.key))
        order = self.runner.commit(client.job_id, tenant="tenant-A", session="paired-A")
        self.assertEqual(order["status"], "confirmed_simulated")
        self.assertEqual(self.store.submit_attempts, 1)
        with self.assertRaises(Denied):
            self.runner.commit(client.job_id, tenant="tenant-A", session="paired-A")
        self.assertEqual(self.store.submit_attempts, 1)
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 0)

    def test_browser_read_token_cannot_call_effect_or_merchant_api(self):
        ctx = ssl.create_default_context(cafile=self.shop_fixture.cert)
        body = {"cart_id": "fake", "sku": "FAKE-ALICE-1", "quantity": 1}
        for endpoint in ("/cart", "/quote", "/commit"):
            req = urllib.request.Request(self.shop_fixture.shop.url + endpoint,
                data=json.dumps(body).encode(), method="POST",
                headers={"Authorization": "Bearer " + self.store.browser_read_secret,
                         "Content-Type": "application/json"})
            with self.subTest(endpoint=endpoint), self.assertRaises(urllib.error.HTTPError) as err:
                urllib.request.urlopen(req, context=ctx, timeout=3)
            self.assertEqual(err.exception.code, 403)
        req = urllib.request.Request(self.shop_fixture.shop.url + "/browse/search?q=keyboard",
            headers={"Authorization": "Bearer " + self.shop_fixture.shop_secret})
        with self.assertRaises(urllib.error.HTTPError) as err:
            urllib.request.urlopen(req, context=ctx, timeout=3)
        self.assertEqual(err.exception.code, 403)
        self.assertEqual(self.store.submit_attempts, 0)

    def test_browser_redirect_does_not_forward_read_secret_to_other_origin(self):
        canary_store = FictionalStore(secret=secrets.token_urlsafe(32))
        with FixtureHTTPS(canary_store, self.shop_fixture.cert, self.shop_fixture.key) as other:
            job = self.client()
            try:
                for target in (other.url + "/r02-redirect-canary",
                               self.shop_fixture.shop.url + "/r02-redirect-canary"):
                    self.store.redirect_browser_to = target
                    with self.assertRaises(Denied):
                        job.step()
            finally:
                self.store.redirect_browser_to = None
                self.adapter.release_session(job.job_id)
            self.assertEqual(canary_store.redirect_hits, 0)
            self.assertFalse(canary_store.redirect_auth_header_seen)
            self.assertEqual(self.store.redirect_hits, 0)
            self.assertEqual(self.store.submit_attempts, 0)

    def test_real_browser_rejects_privileged_operations_and_price_change(self):
        client = self.client()
        first = client.step()
        for malicious in ({"action": "browser_exec", "script": "fetch('/commit')", "epoch": first["epoch"]},
                          {"action": "http", "url": "https://outside.example", "epoch": first["epoch"]},
                          {"action": "shell", "command": "env", "epoch": first["epoch"]},
                          {"action": "checkout_commit", "epoch": first["epoch"]}):
            with self.assertRaises(Denied):
                self.runner.propose(client.job_id, tenant="tenant-A", session="paired-A", proposal=malicious)
        # Consume the remaining scripted steps after the first search.
        client.step()
        client.step()
        client.step()
        client.step()
        challenge = self.runner.challenge(client.job_id, tenant="tenant-A", session="paired-A")
        self.runner.approve(client.job_id, tenant="tenant-A", session="paired-A",
                            signature=fixture.signed(challenge, self.key))
        self.store.price_override = 2899
        with self.assertRaises(Denied):
            self.runner.commit(client.job_id, tenant="tenant-A", session="paired-A")
        self.assertEqual(self.store.submit_attempts, 0)
        self.adapter.release_session(client.job_id)

    def test_separate_browser_contexts_and_human_revocation(self):
        one = self.client(tenant="tenant-A", session="paired-A")
        two = self.client(tenant="tenant-B", session="paired-B")
        one.step()
        two.step()
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 2)
        with self.assertRaises(Denied):
            self.runner.propose(one.job_id, tenant="tenant-B", session="paired-B",
                                proposal={"action": "search", "query": "keyboard", "epoch": 1})
        one.run_to_approval()
        handoff = self.runner.human_handoff(one.job_id, tenant="tenant-A", session="paired-A")
        self.assertEqual(handoff["status"], "awaiting_human_finalization")
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 1)
        with self.assertRaises(Denied):
            self.runner.propose(one.job_id, tenant="tenant-A", session="paired-A",
                                proposal={"action": "search", "query": "keyboard", "epoch": 6})
        self.assertEqual(self.runner.human_finalize(one.job_id, tenant="tenant-A",
                                                    human_handle=handoff["human_handle"])["payment_claim"],
                         "NOT_VERIFIED")
        self.assertEqual(self.store.submit_attempts, 0)
        self.adapter.release_session(two.job_id)

    def test_unseen_browser_session_never_gets_a_false_close_ack(self):
        # Run after other browser tests (alphabetic unittest ordering). A new
        # process cannot attest to termination of a prior-process browser.
        with self.assertRaises(Denied):
            self.adapter.release_session("unowned-real-browser-job-123")
        self.assertIsNone(self.adapter._child.poll())

    def test_unopened_job_handoff_does_not_kill_other_browser_sessions(self):
        unopened = self.client(tenant="tenant-A", session="paired-A")
        researching = self.client(tenant="tenant-B", session="paired-B")
        researching.step()
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 1)
        handoff = self.runner.human_handoff(unopened.job_id, tenant="tenant-A", session="paired-A")
        self.assertEqual(handoff["status"], "awaiting_human_finalization")
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 1)
        researching.step()
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 1)
        self.adapter.release_session(researching.job_id)

    def test_real_browser_merchant_failure_stays_unknown_no_retry(self):
        client = self.client()
        client.run_to_approval()
        self.runner.approve(client.job_id, tenant="tenant-A", session="paired-A",
                            signature=fixture.signed(self.runner.challenge(client.job_id,
                                            tenant="tenant-A", session="paired-A"), self.key))
        self.store.fail_next_submit = True
        with self.assertRaises(Indeterminate):
            self.runner.commit(client.job_id, tenant="tenant-A", session="paired-A")
        with self.assertRaises(Denied):
            self.runner.commit(client.job_id, tenant="tenant-A", session="paired-A")
        self.assertEqual(self.store.submit_attempts, 1)
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 0)

    def test_stopped_browser_job_releases_only_its_own_session(self):
        a = self.client(tenant="tenant-A", session="paired-A")
        b = self.client(tenant="tenant-B", session="paired-B")
        a.step()
        b.step()
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 2)
        result = self.runner.propose(a.job_id, tenant="tenant-A", session="paired-A",
                                     proposal={"action": "stop", "epoch": 1})
        self.assertTrue(result["browser_cleanup_verified"])
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 1)
        b.step()
        self.assertEqual(self.adapter.fixture_stats()["sessions"], 1)
        self.adapter.release_session(b.job_id)
