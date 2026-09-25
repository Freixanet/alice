"""One payment per order: the ledger, not the model, stops a second payment on the same shop.

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "purchases.py"
spec = importlib.util.spec_from_file_location("alice_purchases_test", PATH)
purchases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(purchases)

GATEWAYS = {"sis.redsys.es"}
NOW = 1_800_000_000.0


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def test_the_shop_is_the_page_next_to_the_banks(self):
        tabs = ["https://sis.redsys.es/sis/realizarPago", "https://www.piensosraposo.es/checkout"]
        self.assertEqual(purchases.merchant(tabs, "https://sis.redsys.es", GATEWAYS), "piensosraposo.es")
        self.assertEqual(purchases.merchant([], "https://www.shop.es", GATEWAYS), "shop.es")

    def test_a_first_payment_is_not_in_the_way(self):
        self.assertIsNone(purchases.guard(self.home, "shop.es", now=NOW))

    def test_an_unsettled_payment_blocks_the_next_one(self):
        purchases.record(self.home, "https://www.shop.es", now=NOW)
        verdict = purchases.guard(self.home, "shop.es", now=NOW + 120)
        self.assertEqual(verdict["action"], "block")
        self.assertIn("purchase_outcome", verdict["message"])
        # Another shop is not affected.
        self.assertIsNone(purchases.guard(self.home, "other.es", now=NOW + 120))

    def test_paid_or_unknown_asks_the_person_each_time(self):
        purchases.record(self.home, "shop.es", now=NOW)
        purchases.settle(self.home, "www.shop.es", "paid", order="A-123", now=NOW + 60)
        first = purchases.guard(self.home, "shop.es", now=NOW + 120)
        second = purchases.guard(self.home, "shop.es", now=NOW + 121)
        self.assertEqual(first["action"], "approve")
        self.assertIn("A-123", first["message"])
        self.assertNotEqual(first["rule_key"], second["rule_key"], "«always allow» must not cover a repeat")

        purchases.record(self.home, "b.es", now=NOW)
        purchases.settle(self.home, "b.es", "unknown", now=NOW + 60)
        self.assertEqual(purchases.guard(self.home, "b.es", now=NOW + 120)["action"], "approve")

    def test_declined_or_not_charged_lets_it_try_again(self):
        purchases.record(self.home, "shop.es", now=NOW)
        purchases.settle(self.home, "shop.es", "declined", now=NOW + 60)
        self.assertIsNone(purchases.guard(self.home, "shop.es", now=NOW + 120))

    def test_a_day_later_nothing_stands_in_the_way(self):
        purchases.record(self.home, "shop.es", now=NOW)
        self.assertIsNone(purchases.guard(self.home, "shop.es", now=NOW + purchases.WINDOW + 1))

    def test_settling_needs_a_real_outcome_and_a_recorded_payment(self):
        self.assertFalse(purchases.settle(self.home, "shop.es", "paid", now=NOW)["ok"])
        purchases.record(self.home, "shop.es", now=NOW)
        self.assertFalse(purchases.settle(self.home, "shop.es", "maybe", now=NOW)["ok"])
        self.assertTrue(purchases.run_tool(self.home, {"site": "shop.es", "outcome": "not_charged"})["ok"])

    def test_the_ledger_keeps_no_card_data_and_is_private(self):
        purchases.record(self.home, "shop.es", now=NOW)
        path = self.home / ".alice" / "purchases.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(set(json.loads(path.read_text())[0]), {"id", "shop", "at", "session", "status"})

    def test_a_broken_ledger_does_not_break_a_payment(self):
        path = self.home / ".alice" / "purchases.json"
        path.parent.mkdir(parents=True)
        path.write_text("{not json")
        self.assertIsNone(purchases.guard(self.home, "shop.es", now=NOW))
        purchases.record(self.home, "shop.es", now=NOW)
        self.assertEqual(purchases.guard(self.home, "shop.es", now=NOW + 1)["action"], "block")

    def test_the_prompt_fits_and_asks_for_the_best_working_code(self):
        text = purchases.prompt()
        self.assertLess(len(text), 4000)
        self.assertIn("Código de descuento", text)
        self.assertIn("purchase_outcome", text)


if __name__ == "__main__":
    unittest.main()
