import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("alice_product_list", Path(__file__).parents[1] / "product_list.py")
product_list = importlib.util.module_from_spec(spec)
spec.loader.exec_module(product_list)


def item(**extra):
    return {"title": "Sony WH-CH720N", "price": "69,99 €", "url": "https://www.elcorteingles.es/x", **extra}


class ProductListTests(unittest.TestCase):
    def test_products_with_pages_and_prices_are_shown(self):
        result = product_list.check({"products": [item(original_price="129 €", recommended=True), item()]})
        self.assertEqual((result["ok"], result["shown"]), (True, 2))

    def test_a_card_needs_an_https_page_and_a_price(self):
        with self.assertRaisesRegex(product_list.ProductListError, "https"):
            product_list.check({"products": [item(url="http://shop.example/x")]})
        with self.assertRaisesRegex(product_list.ProductListError, "title and price"):
            product_list.check({"products": [item(price="")]})

    def test_one_pick_at_most_and_six_products_at_most(self):
        with self.assertRaisesRegex(product_list.ProductListError, "one pick"):
            product_list.check({"products": [item(recommended=True), item(recommended=True)]})
        with self.assertRaisesRegex(product_list.ProductListError, "At most 6"):
            product_list.check({"products": [item()] * 7})

    def test_comparing_and_recommending_products_is_research(self):
        for text in ("Busca los 3 mejores auriculares con cancelación de ruido por menos de 200 €",
                     "compara estos dos portátiles", "¿qué robot aspirador me recomiendas?"):
            self.assertTrue(product_list.is_research(text), text)
        self.assertFalse(product_list.is_research("¿qué tiempo hace mañana?"))


if __name__ == "__main__":
    unittest.main()
