"""Local HTTPS model proposal → trusted Alice typed action; no actual Hermes."""

from __future__ import annotations

import importlib.util
import json
import os
import secrets
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace

from alice_secure_runner.coordinator import PairedRemoteCoordinator
from alice_secure_runner.core import AliceRunner, Denied, FictionalHTTPSAdapter
from alice_secure_runner.planner_mailbox import LoopbackPlannerHTTPS, PlannerMailbox
import test_alice_secure_runner as fixtures


PLUGIN = Path(__file__).resolve().parents[1] / "hermes-plugin"


def load(filename):
    spec = importlib.util.spec_from_file_location(
        "alice_remote_" + filename.replace(".", "_"), PLUGIN / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


remote = load("r02_remote.py")
planner = load("r02_planner.py")


class StubModel:
    def __init__(self, actions):
        self.actions = iter(actions)
        self.calls = []

    def complete_structured(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(parsed=next(self.actions))


class PlannerMailboxHTTPSContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures.RunnerHTTPSContractTests.setUpClass()
        cls.fixture = fixtures.RunnerHTTPSContractTests

    @classmethod
    def tearDownClass(cls):
        cls.fixture.tearDownClass()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="alice-r02-planner-")
        self.addCleanup(self.tmp.cleanup)
        folder = Path(self.tmp.name)
        self.mailbox = PlannerMailbox(folder / "planner.sqlite3")
        self.addCleanup(self.mailbox.close)
        self.pair = self.mailbox.create_pair(
            tenant="tenant-a", session="session-a", account="alice-owner",
            installation="disposable-hermes-1")
        self.pair_id = self.pair["pair_id"]
        self.token = self.pair["proposal_only_token"]
        self.runner = AliceRunner(
            FictionalHTTPSAdapter(
                origin=self.fixture.shop.url, ca_file=self.fixture.cert,
                merchant_token=self.fixture.shop_secret),
            approval_key=secrets.token_bytes(32), ledger_path=folder / "runner.sqlite3")
        self.addCleanup(self.runner.close)
        self.job = self.runner.new_job("tenant-a", "session-a", "Fictional delivery")
        self.api = LoopbackPlannerHTTPS(self.mailbox, self.fixture.cert, self.fixture.key)
        self.api.__enter__()
        self.addCleanup(lambda: self.api.__exit__(None, None, None))
        self.bearer_file = folder / "bearer"
        self.bearer_file.write_text(self.token, encoding="ascii")
        self.bearer_file.chmod(0o600)
        self.config = {"origin": self.api.url, "ca_file": self.fixture.cert,
                       "bearer_file": str(self.bearer_file)}
        with self.fixture.store._lock:
            self.fixture.store.carts.clear()
            self.fixture.store.orders.clear()
            self.fixture.store.submit_attempts = 0

    def publish(self, observation):
        return self.mailbox.publish(
            self.pair_id, tenant="tenant-a", session="session-a",
            job_id=self.job["job_id"], epoch=observation["epoch"],
            goal="Research a fictional keyboard", observation=observation)

    def test_five_remote_proposals_traverse_https_into_trusted_alice_runner(self):
        model = StubModel([
            {"action": "search", "query": "keyboard", "epoch": 0},
            {"action": "read_product", "sku": "FAKE-ALICE-1", "epoch": 1},
            {"action": "select_product", "sku": "FAKE-ALICE-1", "epoch": 2},
            {"action": "add_to_cart", "quantity": 2, "epoch": 3},
            {"action": "prepare_checkout", "epoch": 4},
        ])
        ctx = SimpleNamespace(llm=model)
        observation = {"epoch": 0, "status": "researching", "recipient": "PRIVATE ADDRESS"}
        statuses = []
        for _ in range(5):
            step_id = self.publish(observation)
            pending = self.mailbox.pending(self.token)
            self.assertNotIn("recipient", json.dumps(pending))
            self.assertFalse(pending["execution_authority"])
            self.assertEqual(remote.plan_once(
                ctx, config=self.config, planner_module=planner),
                {"status": "submitted_untrusted", "execution_authority": False})
            self.assertEqual(self.mailbox.pending(self.token)["status"], "idle")
            claimed = self.mailbox.claim(
                self.pair_id, tenant="tenant-a", session="session-a", step_id=step_id)
            with self.assertRaises(Denied):
                self.mailbox.claim(
                    self.pair_id, tenant="tenant-a", session="session-a", step_id=step_id)
            observation = self.runner.propose(
                claimed["job_id"], tenant="tenant-a", session="session-a",
                proposal=claimed["proposal"])
            self.mailbox.acknowledge(
                self.pair_id, step_id=step_id, result_status=observation["status"])
            statuses.append(observation["status"])
        self.assertEqual(statuses,
                         ["researching", "researching", "selecting",
                          "cart_ready", "awaiting_approval"])
        self.assertEqual(self.fixture.store.submit_attempts, 0)
        self.assertEqual(len(model.calls), 5)
        self.assertEqual(observation["checkout"]["amount_minor"], 4998)
        self.assertTrue(all("runner_secret" not in str(call) for call in model.calls))

    def test_capability_is_read_and_propose_only_and_revoke_ends_access(self):
        step_id = self.publish({"epoch": 0, "status": "researching"})
        good = self.mailbox.pending(self.token)
        with self.assertRaises(Denied):
            self.mailbox.submit(self.token, step_id=step_id, nonce=good["nonce"],
                                proposal={"action": "checkout_commit", "epoch": 0})
        with self.assertRaises(Denied):
            self.mailbox.submit(self.token, step_id=step_id, nonce=good["nonce"],
                                proposal={"action": [], "epoch": 0})
        with self.assertRaises(Denied):
            self.mailbox.claim(self.pair_id, tenant="tenant-b", session="session-a",
                               step_id=step_id)
        request = urllib.request.Request(
            self.api.url + "/v1/commit", data=b"{}",
            headers={"Authorization": "Bearer " + self.token}, method="POST")
        import ssl
        with self.assertRaises(urllib.error.HTTPError) as denial:
            urllib.request.urlopen(request, context=ssl.create_default_context(cafile=self.fixture.cert))
        self.assertEqual(denial.exception.code, 404)
        self.mailbox.revoke(self.pair_id, account="alice-owner")
        with self.assertRaises(Denied):
            self.mailbox.pending(self.token)
        with self.assertRaises(Denied):
            self.mailbox.claim(self.pair_id, tenant="tenant-a",
                               session="session-a", step_id=step_id)
        other = PlannerMailbox(Path(self.tmp.name) / "planner.sqlite3")
        try:
            with self.assertRaises(Denied):
                other.pending(self.token)
        finally:
            other.close()

    def test_rotated_secret_rejects_previous_and_claim_is_durable_across_restart(self):
        step = self.publish({"epoch": 0, "status": "researching"})
        pending = self.mailbox.pending(self.token)
        replacement = self.mailbox.rotate(self.pair_id, account="alice-owner")
        with self.assertRaises(Denied):
            self.mailbox.pending(self.token)
        self.mailbox.submit(
            replacement, step_id=step, nonce=pending["nonce"],
            proposal={"action": "search", "query": "keyboard", "epoch": 0})
        self.mailbox.claim(self.pair_id, tenant="tenant-a", session="session-a",
                           step_id=step)
        reopened = PlannerMailbox(Path(self.tmp.name) / "planner.sqlite3")
        try:
            with self.assertRaises(Denied):
                reopened.claim(self.pair_id, tenant="tenant-a", session="session-a",
                               step_id=step)
            self.assertEqual(reopened.pending(replacement)["status"], "idle")
        finally:
            reopened.close()

    def test_trusted_remote_coordinator_recovers_without_new_job_or_duplicate_step(self):
        kwargs = dict(runner=self.runner, mailbox=self.mailbox, tenant="tenant-a",
                      session="session-a", pair_id=self.pair_id,
                      goal="Research a fictional keyboard", recipient="Fictional recipient")
        controller = PairedRemoteCoordinator(**kwargs, existing_job_id=self.job["job_id"])
        step = controller.stage()
        self.assertEqual(controller.stage(), step)
        model = StubModel([{"action": "search", "query": "keyboard", "epoch": 0},
                           {"action": "read_product", "sku": "FAKE-ALICE-1", "epoch": 1}])
        ctx = SimpleNamespace(llm=model)
        self.assertEqual(remote.plan_once(ctx, config=self.config, planner_module=planner)["status"],
                         "submitted_untrusted")
        first = controller.consume(step)
        self.assertEqual(first["epoch"], 1)
        with self.assertRaises(Denied):
            controller.consume(step)
        # A new trusted Alice coordinator resumes from the old durable job,
        # never launches another checkout or silently resets the cart.
        restored = PairedRemoteCoordinator(**kwargs, existing_job_id=self.job["job_id"])
        another = restored.stage()
        self.assertNotEqual(step, another)
        remote.plan_once(ctx, config=self.config, planner_module=planner)
        second = restored.consume(another)
        self.assertEqual(second["epoch"], 2)
        self.assertEqual(self.fixture.store.submit_attempts, 0)

    def test_optional_remote_registration_fails_closed_when_unconfigured(self):
        tools = {}
        ctx = SimpleNamespace(
            llm=StubModel([]),
            register_tool=lambda **kw: tools.__setitem__(kw["name"], kw))
        remote.register(ctx, planner)
        self.assertEqual(set(tools), {"alice_secure_plan_remote"})
        handler = tools["alice_secure_plan_remote"]["handler"]
        from unittest.mock import patch
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(json.loads(handler({})),
                             {"status": "denied", "execution_authority": False})
        self.assertEqual(json.loads(handler({"commit": True})),
                         {"status": "denied", "execution_authority": False})

    def test_official_tool_handler_uses_configured_proposal_capability_only(self):
        submitted = {"action": "search", "query": "fictional keyboard", "epoch": 0}
        model = StubModel([submitted])
        registered = {}
        ctx = SimpleNamespace(
            llm=model, register_tool=lambda **kw: registered.__setitem__(kw["name"], kw))
        remote.register(ctx, planner)
        self.publish({"epoch": 0, "status": "researching",
                      "recipient": "NOT PERMITTED IN OBSERVATIONS"})
        from unittest.mock import patch
        with patch.dict(os.environ, {
                "ALICE_R02_PLANNER_ORIGIN": self.api.url,
                "ALICE_R02_PLANNER_CA_FILE": self.fixture.cert,
                "ALICE_R02_PLANNER_BEARER_FILE": str(self.bearer_file)}):
            callback = registered["alice_secure_plan_remote"]["handler"]
            self.assertEqual(json.loads(callback({})),
                             {"status": "submitted_untrusted", "execution_authority": False})
            self.assertEqual(json.loads(callback({})),
                             {"status": "idle", "execution_authority": False})
        self.assertEqual(len(model.calls), 1)
        self.assertEqual(self.fixture.store.submit_attempts, 0)

    def test_pair_expiry_and_bad_file_permissions_deny_http_proposal(self):
        self.publish({"epoch": 0, "status": "researching"})
        self.bearer_file.chmod(0o644)
        with self.assertRaises(remote.RemotePlanningDenied):
            remote.plan_once(
                SimpleNamespace(llm=StubModel([])), config=self.config,
                planner_module=planner)
        self.bearer_file.chmod(0o600)
        with self.assertRaises(Denied):
            self.mailbox.submit(
                "forged-proposal-only-credential" * 2, step_id="wrong",
                nonce="wrong", proposal={"action": "stop", "epoch": 0})
        expiring = self.mailbox.create_pair(
            tenant="tenant-b", session="session-b", account="owner-b",
            installation="fixture-b", expires_in=1)
        self.mailbox._clock = lambda: __import__("time").time() + 10
        with self.assertRaises(Denied):
            self.mailbox.pending(expiring["proposal_only_token"])

    def test_two_sqlite_connections_cannot_accept_conflicting_proposals(self):
        step = self.publish({"epoch": 0, "status": "researching"})
        nonce = self.mailbox.pending(self.token)["nonce"]
        second = PlannerMailbox(Path(self.tmp.name) / "planner.sqlite3")
        self.addCleanup(second.close)
        start = threading.Barrier(3)
        outcomes = []

        def propose(store, query):
            start.wait()
            try:
                store.submit(
                    self.token, step_id=step, nonce=nonce,
                    proposal={"action": "search", "query": query, "epoch": 0})
                outcomes.append(("accepted", query))
            except Denied:
                outcomes.append(("denied", query))

        first = threading.Thread(target=propose, args=(self.mailbox, "keyboard"))
        other = threading.Thread(target=propose, args=(second, "headphones"))
        first.start()
        other.start()
        start.wait()
        first.join(timeout=5)
        other.join(timeout=5)
        self.assertFalse(first.is_alive() or other.is_alive())
        self.assertEqual(sorted(result[0] for result in outcomes),
                         ["accepted", "denied"])
        claimed = self.mailbox.claim(
            self.pair_id, tenant="tenant-a", session="session-a", step_id=step)
        self.assertIn(claimed["proposal"]["query"], ("keyboard", "headphones"))


if __name__ == "__main__":
    unittest.main()
