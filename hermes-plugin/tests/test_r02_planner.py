"""Mock-only Alice structured planner tests: never access runner or Hermes LLM."""
import importlib.util
import json
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock


spec = importlib.util.spec_from_file_location(
    "r02_planner_test", Path(__file__).resolve().parents[1] / "r02_planner.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class PlannerTests(unittest.TestCase):
    def ctx(self, answer):
        llm = Mock(return_value=SimpleNamespace(parsed=answer))
        return SimpleNamespace(llm=SimpleNamespace(complete_structured=llm)), llm

    def test_representative_six_step_sequence_with_independent_observations(self):
        history = []
        actions = [
            {"action": "search", "query": "creatine", "epoch": 0},
            {"action": "read_product", "sku": "SKU-1", "epoch": 1},
            {"action": "select_product", "sku": "SKU-1", "epoch": 2},
            {"action": "add_to_cart", "quantity": 2, "epoch": 3},
            {"action": "prepare_checkout", "epoch": 4},
            {"action": "stop", "epoch": 5},
        ]
        for epoch, expected in enumerate(actions):
            ctx, llm = self.ctx(expected)
            self.assertEqual(planner.propose(ctx, goal="Buy creatine", observations=history, epoch=epoch), expected)
            received = json.loads(llm.call_args.kwargs["input"][0]["text"])
            self.assertEqual(received["epoch"], epoch)
            self.assertEqual(len(received["observations"]), epoch)
            self.assertNotIn("model", llm.call_args.kwargs)
            history.append({"epoch": epoch, "status": "ok", "sku": "SKU-1"})

    def test_each_action_requires_exact_keys_and_integer_epoch(self):
        valid = {"action": "stop", "epoch": 0}
        for bad in (None, {}, {"action": "stop"}, {**valid, "extra": "x"},
                    {"action": "stop", "epoch": True}, {"action": "stop", "epoch": "0"},
                    {"action": "stop", "epoch": 1},
                    {"action": "search", "epoch": 0},
                    {"action": "read_product", "sku": "SKU", "epoch": 0, "query": "x"},
                    {"action": "checkout_commit", "epoch": 0}):
            with self.subTest(bad=bad):
                ctx, _ = self.ctx(bad)
                with self.assertRaises(planner.InvalidProposal):
                    planner.propose(ctx, goal="Get item", observations=[], epoch=0)

    def test_action_specific_boundaries(self):
        for bad in ({"action": "search", "query": "", "epoch": 0},
                    {"action": "search", "query": "x" * 101, "epoch": 0},
                    {"action": "select_product", "sku": "", "epoch": 0},
                    {"action": "read_product", "sku": None, "epoch": 0},
                    {"action": "add_to_cart", "quantity": 0, "epoch": 0},
                    {"action": "add_to_cart", "quantity": True, "epoch": 0},
                    {"action": "add_to_cart", "quantity": 6, "epoch": 0}):
            with self.subTest(bad=bad):
                ctx, _ = self.ctx(bad)
                with self.assertRaises(planner.InvalidProposal):
                    planner.propose(ctx, goal="Get item", observations=[], epoch=0)

    def test_raw_observations_redacted_and_unknown_fields_removed(self):
        ctx, llm = self.ctx({"action": "stop", "epoch": 0})
        planner.propose(ctx, goal="search alice@example.com", epoch=0, observations=[{
            "products": [{"sku": "S1", "name": "safe product"}],
            "access_token": "SUPER_PRIVATE", "recipient": "home address",
            "description": "Bearer 1234 email alice@example.com", "status": "ok",
        }])
        serialized = llm.call_args.kwargs["input"][0]["text"]
        for secret in ("SUPER_PRIVATE", "home address", "alice@example.com", "Bearer"):
            self.assertNotIn(secret, serialized)
        self.assertIn("S1", serialized)

    def test_input_bounds_and_no_llm_when_invalid(self):
        ctx, llm = self.ctx({"action": "stop", "epoch": 0})
        for args in ({"epoch": True, "observations": []},
                     {"epoch": -1, "observations": []},
                     {"epoch": 0, "observations": [None] * 25},
                     {"epoch": 0, "observations": [{"name": "x" * 9000}]}):
            with self.subTest(args=args):
                with self.assertRaises(planner.InvalidProposal):
                    planner.propose(ctx, goal="Get item", **args)
        llm.assert_not_called()

    def test_unavailable_api_never_falls_back_to_runner_or_runs(self):
        for ctx in (SimpleNamespace(), SimpleNamespace(llm=SimpleNamespace())):
            with self.assertRaises(planner.PlannerUnavailable):
                planner.propose(ctx, goal="Get item", observations=[], epoch=0)
        ctx = SimpleNamespace(llm=SimpleNamespace(complete_structured=Mock(side_effect=RuntimeError("offline"))))
        with self.assertRaises(planner.PlannerUnavailable):
            planner.propose(ctx, goal="Get item", observations=[], epoch=0)


if __name__ == "__main__":
    unittest.main()
