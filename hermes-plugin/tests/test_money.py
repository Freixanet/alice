"""Amounts read once, as cents and a currency: models write prices every way.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("alice_money_test", Path(__file__).resolve().parents[1] / "money.py")
money = importlib.util.module_from_spec(spec)
spec.loader.exec_module(money)


class MoneyTests(unittest.TestCase):
    def test_invalid_or_ambiguous_prices_are_not_guessed(self):
        for value in (-1, float('nan'), float('inf'), '-27,98 €', '27 € / 30 €',
                      '12.34.56 EUR', '27,98 EUR USD', '27.9812 EUR'):
            with self.subTest(value=value):
                self.assertIsNone(money.parse(value))
        self.assertIsNone(money.parse('$27.98', 'EUR'))
        self.assertIsNone(money.parse('€27.98 USD'))

    def test_every_way_a_price_is_written(self):
        cases = {
            "27,98 €": (2798, "EUR"), "€27.98": (2798, "EUR"), "EUR 27.98": (2798, "EUR"),
            "1.234,56 EUR": (123456, "EUR"), "1,234.56 USD": (123456, "USD"), "$12": (1200, "USD"),
            "20,9 €": (2090, "EUR"), "1.234 €": (123400, "EUR"), "34,99": (3499, ""),
        }
        for written, expected in cases.items():
            self.assertEqual(money.parse(written), expected, written)
        self.assertEqual(money.parse(27.98, "EUR"), (2798, "EUR"))
        for nothing in ("consultar", "", None, True):
            self.assertIsNone(money.parse(nothing))

    def test_the_decimal_mark_is_never_lost(self):
        # Comparing digits made «27,98 €» and «2798 €» the same amount.
        self.assertFalse(money.same("27,98 €", "2798 €"))
        self.assertTrue(money.same("27,98 €", "EUR 27.98"))
        self.assertFalse(money.same("27,98 €", "$27.98"))
        self.assertTrue(money.same("27,98 €", 27.98))

    def test_cents_as_a_person_reads_them(self):
        self.assertEqual(money.text(2798, "EUR"), "27,98 €")
        self.assertEqual(money.text(123456, "EUR"), "1.234,56 €")
        self.assertEqual(money.text(1195, "USD"), "$11.95")


if __name__ == "__main__":
    unittest.main()
