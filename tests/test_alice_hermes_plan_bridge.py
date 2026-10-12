"""Mock official Hermes ctx.llm -> actual Alice coordinator -> fictitious HTTPS store.

No live Hermes/model process, tools or credentials: this only proves the
protocol adapter works with the exact official ctx.llm result shape.
"""

from __future__ import annotations

import importlib.util
import secrets
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

from alice_secure_runner.coordinator import Coordinator
from alice_secure_runner.core import AliceRunner, Denied, FictionalHTTPSAdapter
import test_alice_secure_runner as shop_tests


SPEC = importlib.util.spec_from_file_location(
    "alice_proto_structured_hermes_planner", Path(__file__).resolve().parents[1] / "hermes-plugin" / "r02_planner.py")
hermes_planner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hermes_planner)


class ModelStub:
    def __init__(self, outputs):
        self.outputs = iter(outputs)
        self.calls = []

    def complete_structured(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(parsed=next(self.outputs))


class HermesOfficialPlannerAdapter:
    def __init__(self, stub):
        self.ctx = SimpleNamespace(llm=stub)
        self.observations = []

    def next_action(self, observation):
        self.observations.append(observation)
        return hermes_planner.propose(self.ctx, goal="Research a fictional keyboard",
                                      observations=self.observations, epoch=observation["epoch"])


class StructuredBridgeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shop_tests.RunnerHTTPSContractTests.setUpClass()
        cls.fixture = shop_tests.RunnerHTTPSContractTests

    @classmethod
    def tearDownClass(cls):
        cls.fixture.tearDownClass()

    def setUp(self):
        store = self.fixture.store
        with store._lock:
            store.carts.clear()
            store.orders.clear()
            store.submit_attempts = 0
            store.price_override = None
            store.fail_next_quote = False
        self.store = store
        self.runner = AliceRunner(FictionalHTTPSAdapter(
            origin=self.fixture.shop.url, ca_file=self.fixture.cert,
            merchant_token=self.fixture.shop_secret), approval_key=secrets.token_bytes(32))

    def test_real_https_actions_from_mock_ctx_llm_multi_step(self):
        steps = [
            {"action": "search", "query": "keyboard", "epoch": 0},
            {"action": "read_product", "sku": "FAKE-ALICE-1", "epoch": 1},
            {"action": "select_product", "sku": "FAKE-ALICE-1", "epoch": 2},
            {"action": "add_to_cart", "quantity": 2, "epoch": 3},
            {"action": "prepare_checkout", "epoch": 4},
        ]
        stub = ModelStub(steps)
        coord = Coordinator(self.runner, tenant="alice-tenant", session="official-Hermes-stub",
                            recipient="Fictional recipient", planner=HermesOfficialPlannerAdapter(stub))
        result = coord.run_to_approval()
        self.assertEqual(result["checkout"]["amount_minor"], 4998)
        self.assertEqual(len(stub.calls), 5)
        self.assertEqual(self.store.submit_attempts, 0)
        for call in stub.calls:
            self.assertEqual(call["schema_name"], "alice_r02_action")
            self.assertNotIn("model", call)
            self.assertNotIn("provider", call)
            self.assertNotIn("runner_secret", str(call))

    def test_malicious_hermes_proposal_denied_before_shop_effect(self):
        stub = ModelStub([{"action": "checkout_commit", "epoch": 0}])
        coord = Coordinator(self.runner, tenant="alice-tenant", session="official-Hermes-stub",
                            recipient="Fictional recipient", planner=HermesOfficialPlannerAdapter(stub))
        with self.assertRaises(hermes_planner.InvalidProposal):
            coord.step()
        self.assertEqual(self.store.submit_attempts, 0)


if __name__ == "__main__":
    unittest.main()
