"""R02 DOM inspection contract: no browser, secrets or external requests."""
import importlib.util
import json
import unittest
from pathlib import Path
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / "errand_dom_read.py"
spec = importlib.util.spec_from_file_location("alice_dom_read_unit_test", SOURCE)
dom = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dom)


class DomReadTests(unittest.TestCase):
    def setUp(self):
        self.entry = {"id": "example", "offer": {"url": "https://shop.example/item"}}
        self.own = ("https://shop.example", {"target": "tab-1", "context": "isolated-1"}, None)

    def test_read_products_and_prices_uses_a_fixed_script_and_pinned_tab(self):
        result = dom.read(self.entry, {"selectors": ["#title", ".price"]},
                          inspect=lambda entry: self.own,
                          evaluate=lambda context, javascript: [
                              {"selector": "#title", "matches": [{"text": "Creatina 500 g"}]},
                              {"selector": ".price", "matches": [{"text": "34,99 €"}]},
                          ])
        self.assertEqual(result["results"][0]["matches"][0]["text"], "Creatina 500 g")
        self.assertEqual(result["results"][1]["matches"][0]["text"], "34,99 €")
        self.assertLess(len(json.dumps(result).encode()), 4096)

    def test_selector_is_escaped_data_not_model_javascript(self):
        supplied = "#product\\\"});globalThis.charge();/*"
        captured = []

        def evaluate(_context, code):
            captured.append(code)
            self.assertIn(json.dumps(supplied), code)
            self.assertNotIn("el.textContent", code)
            # The sole occurrence of the malicious phrase is inside JSON data.
            self.assertEqual(code.count("globalThis.charge()"), 1)
            return [{"selector": supplied, "matches": [{"text": "Nothing charged"}]}]

        value = dom.read(self.entry, {"selectors": [supplied]},
                         inspect=lambda entry: self.own, evaluate=evaluate)
        self.assertTrue(value["ok"])
        self.assertEqual(len(captured), 1)

    def test_sensitive_selectors_excessive_input_and_raw_code_are_rejected_before_eval(self):
        evaluator = mock.Mock(side_effect=AssertionError("should never run"))
        for args in (
            {"selectors": ["body"]}, {"selectors": ["*"]},
            {"selectors": ["body *"]}, {"selectors": ["html *"]},
            {"selectors": ["*:not(.private)"]},
            {"selectors": ["input[type=password]"]},
            {"selectors": ["#otp"]}, {"selectors": ["#card-number"]},
            {"selectors": ["a:has(img)"]},
            {"selectors": [".x"] * 9}, {"selectors": [".x"], "expression": "pay()"},
            {"selectors": [".x"], "script": "document.cookie"},
        ):
            with self.subTest(args=args):
                with self.assertRaises(ValueError):
                    dom.read(self.entry, args, inspect=lambda entry: self.own,
                             evaluate=evaluator)
        evaluator.assert_not_called()
        common = [".product-selector", ".author", ".product-description", ".variant-selector", ".platform"]
        self.assertEqual(dom._selectors({"selectors": common}), common)

    def test_unpinned_wrong_site_or_missing_offer_cannot_read(self):
        evaluator = mock.Mock(side_effect=AssertionError("should never run"))
        for entry, context in (
            (self.entry, ("https://other.example", self.own[1], None)),
            (self.entry, ("https://shop.example", {"target": "tab-1"}, None)),
            ({"id": "example", "offer": None}, self.own),
        ):
            with self.subTest(entry=entry, context=context):
                with self.assertRaises(ValueError):
                    dom.read(entry, {"selectors": [".price"]},
                             inspect=lambda _entry: context, evaluate=evaluator)
        evaluator.assert_not_called()

    def test_redacts_email_card_data_and_bounds_malformed_results(self):
        fake = [{"selector": ".price", "matches": [
            {"text": "shopper@example.com 4111 1111 1111 1111"},
            {"text": "X" * 300},
        ]}]
        result = dom.read(self.entry, {"selectors": [".price"]},
                          inspect=lambda entry: self.own,
                          evaluate=lambda context, source: fake)
        result_text = json.dumps(result)
        self.assertNotIn("shopper@example.com", result_text)
        self.assertNotIn("4111", result_text)
        self.assertLessEqual(len(result["results"][0]["matches"][1]["text"]), dom.MAX_TEXT)
        with self.assertRaises(ValueError):
            dom.read(self.entry, {"selectors": [".price"]},
                     inspect=lambda entry: self.own,
                     evaluate=lambda context, source: {"other": "untrusted"})

    def test_switching_targets_during_the_read_fails_closed(self):
        switched = ("https://shop.example", {"target": "tab-2", "context": "isolated-2"}, None)
        inspect = mock.Mock(side_effect=[self.own, switched])
        with self.assertRaisesRegex(ValueError, "cambió"):
            dom.read(self.entry, {"selectors": [".price"]}, inspect=inspect,
                     evaluate=lambda context, source: [
                         {"selector": ".price", "matches": [{"text": "34,99 €"}]}
                     ])
        self.assertEqual(inspect.call_count, 2)

    def test_same_target_but_changed_page_url_is_rejected(self):
        before = ("https://shop.example", {"target": "t1", "context": "ctx", "url": "https://shop.example/item"}, None)
        after = ("https://shop.example", {"target": "t1", "context": "ctx", "url": "https://shop.example/account"}, None)
        inspect = mock.Mock(side_effect=[before, after])
        with self.assertRaisesRegex(ValueError, "cambió"):
            dom.read(self.entry, {"selectors": [".price"]}, inspect=inspect,
                     evaluate=lambda ctx, code: [{"selector": ".price", "matches": [{"text": "34,99 €"}]}])

    def test_full_output_has_a_hard_byte_limit(self):
        selectors = [".price-%03d" % i + ("x" * 100) for i in range(8)]
        many = [{"selector": s, "matches": [{"text": "A" * 140} for _ in range(3)]}
                for s in selectors]
        with self.assertRaisesRegex(ValueError, "demasiados"):
            dom.read(self.entry, {"selectors": selectors}, inspect=lambda _: self.own,
                     evaluate=lambda ctx, code: many)

    def test_invalid_css_does_not_masquerade_as_no_products(self):
        with self.assertRaisesRegex(ValueError, "selector"):
            dom.read(self.entry, {"selectors": ["[malformed"]}, inspect=lambda _: self.own,
                     evaluate=lambda ctx, code: [{"selector": "[malformed", "matches": [],
                                                  "error": "invalid selector"}])


if __name__ == "__main__":
    unittest.main()
