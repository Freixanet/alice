"""The Shop catalog: products with price, stock and page, and four outcomes kept apart.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import unittest
import urllib.error
from pathlib import Path

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "catalog.py"
spec = importlib.util.spec_from_file_location("alice_catalog_test", PATH)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)

PRODUCT = {
    "id": "gid://shopify/p/abc", "title": "Camiseta algodón orgánico",
    "media": [{"type": "image", "url": "https://cdn.shopify.com/camiseta.jpg"}],
    "variants": [{
        "id": "gid://shopify/ProductVariant/1", "price": {"amount": 2500, "currency": "EUR"},
        "availability": {"available": True}, "options": [{"name": "Color", "label": "Blanca"}, {"name": "Size", "label": "S"}],
        "url": "https://minimalismbrand.com/products/camiseta?variant=1", "checkout_url": "https://minimalismbrand.com/cart/1:1",
        "seller": {"name": "Minimalism Brand", "domain": "minimalism.myshopify.com"},
    }],
}


class Recorder:
    def __init__(self, answer):
        self.answer, self.sent = answer, []

    def __call__(self, payload):
        self.sent.append(payload)
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


class SearchTests(unittest.TestCase):
    def test_products_with_price_stock_and_page_for_the_persons_country(self):
        post = Recorder({"result": {"structuredContent": {"products": [PRODUCT]}}})
        out = catalog.search("camiseta blanca", country="es", currency="eur", limit=3, max_price=40, post=post)
        self.assertEqual(out["status"], "ok")
        row = out["products"][0]
        self.assertEqual((row["title"], row["variant"], row["merchant"]),
                         ("Camiseta algodón orgánico", "Blanca / S", "Minimalism Brand"))
        self.assertEqual((row["price"], row["currency"], row["in_stock"]), ("25,00 €", "EUR", True))
        self.assertEqual(row["checkout_url"], "https://minimalismbrand.com/cart/1:1")
        self.assertEqual(row["image"], "https://cdn.shopify.com/camiseta.jpg")
        sent = post.sent[0]["params"]["arguments"]["catalog"]
        self.assertEqual(sent["filters"]["ships_to"], {"country": "ES"})
        self.assertEqual(sent["context"], {"address_country": "ES", "currency": "EUR"})
        self.assertEqual(sent["filters"]["price"], {"max": 4000})
        self.assertEqual(sent["pagination"], {"limit": 3})

    def test_a_price_limit_is_sent_in_exact_cents(self):
        post = Recorder({"result": {"structuredContent": {"products": [PRODUCT]}}})
        catalog.search("camiseta", max_price=19.99, post=post)
        self.assertEqual(post.sent[0]["params"]["arguments"]["catalog"]["filters"]["price"], {"max": 1999})

    def test_unknown_country_and_currency_are_not_invented(self):
        post = Recorder({"result": {"structuredContent": {"products": []}}})
        out = catalog.search("lámpara", post=post)
        self.assertEqual(out["status"], "empty")
        sent = post.sent[0]["params"]["arguments"]["catalog"]
        self.assertNotIn("context", sent)
        self.assertNotIn("ships_to", sent["filters"])

    def test_offline_and_unsupported_are_not_empty(self):
        self.assertEqual(catalog.search("x", post=Recorder(urllib.error.URLError("down")))["status"], "offline")
        self.assertEqual(catalog.search("x", post=Recorder({"error": {"code": -32601}}))["status"], "unsupported")

    def test_only_https_links_are_passed_on(self):
        bad = {**PRODUCT, "variants": [{**PRODUCT["variants"][0], "url": "javascript:alert(1)"}]}
        out = catalog.search("x", post=Recorder({"result": {"structuredContent": {"products": [bad]}}}))
        self.assertEqual(out["products"], [])


class ProductTests(unittest.TestCase):
    def test_the_chosen_variant(self):
        post = Recorder({"result": {"structuredContent": {"product": {
            **PRODUCT, "options": [{"name": "Size", "values": [{"label": "S"}, {"label": "M"}]}]}}}})
        out = catalog.product("gid://shopify/p/abc", selected={"Size": "S"}, country="ES", post=post)
        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["options"], [{"name": "Size", "values": ["S", "M"]}])
        self.assertEqual(post.sent[0]["params"]["arguments"]["catalog"]["selected"], [{"name": "Size", "label": "S"}])

    def test_a_made_up_id_is_not_sent(self):
        post = Recorder({})
        self.assertEqual(catalog.product("abc", post=post)["status"], "empty")
        self.assertEqual(post.sent, [])


class PriceTests(unittest.TestCase):
    def test_prices_as_a_person_reads_them(self):
        self.assertEqual(catalog.price_text(1195, "EUR"), "11,95 €")
        self.assertEqual(catalog.price_text(123456, "EUR"), "1.234,56 €")
        self.assertEqual(catalog.price_text(1195, "USD"), "$11.95")
        self.assertEqual(catalog.price_text(1195, "CHF"), "11.95 CHF")
        self.assertEqual(catalog.price_text(None, "EUR"), "")


if __name__ == "__main__":
    unittest.main()
