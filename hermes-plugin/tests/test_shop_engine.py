"""The shop engine on three fictional shops of three platforms, with no selector from any model.

The pages run in jsdom (tests/fixtures/js_page.cjs) and every request they make is answered by
the fixture shops (tests/fixtures/shops.py), the same ones scripts/verify-shops.py serves to a
real Chrome. Skipped when node or jsdom is missing (`npm ci` installs jsdom).

    NODE_PATH=<dir with jsdom> python -m unittest discover -s hermes-plugin/tests -p test_shop_engine.py
"""
import importlib.util
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).with_name("fixtures")))
import shops  # noqa: E402


def load(name):
    key = "alice_" + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, ROOT / (name + ".py"))
        sys.modules[key] = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sys.modules[key])
    return sys.modules[key]


engine = load("shop_engine")
prices = load("purchase_prices")
JSDOM = shops.jsdom_available()


@unittest.skipUnless(JSDOM, "node with jsdom is needed (npm ci, or NODE_PATH pointing at a jsdom install)")
class Base(unittest.TestCase):
    def open(self, *shop_list):
        self.router = shops.Router(*shop_list)
        self.js = shops.JsPage(self.router)
        self.addCleanup(self.js.close)
        return engine.Page(self.js.evaluate, self.js.goto, self.js.url, sleep=lambda s: None)


class SearchTests(Base):
    def test_each_platform_finds_the_product_with_its_own_search(self):
        for shop, query, title, how in ((shops.ShopifyLike(), "creatina creapure", "Creatina Creapure Monohidrato", "shopify-suggest"),
                                        (shops.WooLike(), "proteina whey", "Proteína Whey Isolate", "woo-store-api"),
                                        (shops.Generic(), "zapatillas trail", "Zapatillas Trail X", "form")):
            with self.subTest(shop=shop.host):
                page = self.open(shop)
                found = engine.search(page, shop.host, query)
                self.assertEqual(found["how"], how)
                self.assertEqual([l["title"] for l in found["links"]], [title])
                self.assertTrue(found["links"][0]["url"].startswith("https://" + shop.host + "/"))

    def test_the_platform_is_told_by_the_page_not_by_the_domain(self):
        for shop, platform in ((shops.ShopifyLike(), "shopify"), (shops.WooLike(), "woocommerce"), (shops.Generic(), "generic")):
            with self.subTest(shop=shop.host):
                page = self.open(shop)
                page.goto(shop.base + "/")
                self.assertEqual(engine.detect(page)["platform"], platform)

    def test_nothing_found_is_said_never_an_empty_list(self):
        page = self.open(shops.Generic())
        with self.assertRaises(ValueError):
            engine.search(page, "tienda-tres.example", "bicicleta eléctrica")

    def test_a_cookie_banner_is_closed_with_its_own_button(self):
        page = self.open(shops.Generic())
        page.goto("https://tienda-tres.example/")
        self.assertTrue(engine.dismiss_cookies(page))
        self.assertTrue(self.js.evaluate("window.consented === true"))


class QuoteTests(Base):
    def test_shopify_reads_the_variant_and_the_basket_from_its_api(self):
        page = self.open(shops.ShopifyLike())
        out = engine.quote(page, "https://tienda-uno.example/products/creatina-creapure", variant="500 g", qty=2, currency="EUR")
        self.assertEqual((out["price_cents"], out["currency"], out["variant"], out["basis"]), (3499, "EUR", "500 g", "cart"))
        self.assertEqual(out["how"]["cart"], "shopify-cart-js")

    def test_woocommerce_reads_the_variation_and_the_basket_from_the_store_api(self):
        page = self.open(shops.WooLike())
        out = engine.quote(page, "https://tienda-dos.example/producto/proteina-whey/", variant="Vainilla", currency="EUR")
        self.assertEqual((out["price_cents"], out["variant"], out["basis"]), (3290, "Vainilla", "cart"))
        self.assertEqual(out["how"]["add"], "woo-store-api")

    def test_a_shop_on_no_platform_is_read_from_structured_data_and_its_cart_page(self):
        shop = shops.Generic()
        page = self.open(shop)
        out = engine.quote(page, "https://tienda-tres.example/p/zapatillas-trail-x", variant="43", qty=2, currency="EUR")
        # The size's own price (94,95 €), not the first offer's (89,95 €) nor the struck-out 120 €.
        self.assertEqual((out["price_cents"], out["basis"], out["cart_qty"]), (9495, "cart", "2"))
        self.assertEqual(out["how"]["product"], "jsonld:variant")
        self.assertEqual(out["how"]["cart"], "dom:cart-page")
        self.assertEqual(shop.cart, [{"slug": "zapatillas-trail-x", "size": "43", "qty": 2}])

    def test_a_public_coupon_counts_only_when_the_basket_applies_it(self):
        page = self.open(shops.Generic())
        out = engine.quote(page, "https://tienda-tres.example/p/zapatillas-trail-x", variant="42", currency="EUR",
                           coupons=["FALSO", "PUBLICO10"])
        self.assertEqual([(r["code"], r["applied"]) for r in out["coupon_results"]], [("FALSO", False), ("PUBLICO10", True)])
        self.assertEqual((out["price_cents"], out["coupon"]), (8096, "PUBLICO10"))

    def test_a_sold_out_variant_is_said_on_every_platform(self):
        for shop, url, variant in ((shops.ShopifyLike(), "https://tienda-uno.example/products/creatina-creapure", "1 kg"),
                                   (shops.WooLike(), "https://tienda-dos.example/producto/proteina-whey/", "Fresa"),
                                   (shops.Generic(), "https://tienda-tres.example/p/zapatillas-trail-x", "44")):
            with self.subTest(shop=shop.host):
                with self.assertRaisesRegex(ValueError, "agotada"):
                    engine.quote(self.open(shop), url, variant=variant, currency="EUR")
                self.assertEqual(shop.cart, [])

    def test_a_variant_the_page_does_not_have_is_not_replaced_by_another(self):
        with self.assertRaisesRegex(ValueError, "variante"):
            engine.quote(self.open(shops.Generic()), "https://tienda-tres.example/p/zapatillas-trail-x", variant="47", currency="EUR")

    def test_a_product_without_variants_needs_none(self):
        out = engine.quote(self.open(shops.Generic()), "https://tienda-tres.example/p/calcetines-trail", currency="EUR")
        self.assertEqual((out["price_cents"], out["basis"]), (1250, "cart"))

    def test_when_no_basket_can_be_read_the_page_price_is_the_quote_said_as_such(self):
        class NoButton(shops.Generic):
            def request(self, method, url, body=""):
                status, ctype, text, headers = super().request(method, url, body)
                return status, ctype, text.replace("Añadir a la cesta", "Ver tiendas"), headers
        out = engine.quote(self.open(NoButton()), "https://tienda-tres.example/p/calcetines-trail", currency="EUR")
        self.assertEqual((out["price_cents"], out["basis"]), (1250, "page"))
        self.assertIn("añadir", out["unverified"])

    def test_the_add_control_never_presses_a_button_that_pays(self):
        class PayOnly(shops.Generic):
            def request(self, method, url, body=""):
                status, ctype, text, headers = super().request(method, url, body)
                return status, ctype, text.replace("Añadir a la cesta", "Comprar ahora y pagar"), headers
        shop = PayOnly()
        out = engine.quote(self.open(shop), "https://tienda-tres.example/p/calcetines-trail", currency="EUR")
        self.assertEqual(out["basis"], "page")
        self.assertEqual(shop.cart, [])


class ErrandCartTests(Base):
    def test_the_errands_basket_and_the_order_total_are_read_without_selectors(self):
        shop = shops.Generic()
        shop.cart = [{"slug": "zapatillas-trail-x", "size": "43", "qty": 2}]
        page = self.open(shop)
        page.goto("https://tienda-tres.example/cesta")
        read = engine.errand_cart(self.js.evaluate, "Zapatillas Trail X", "43", 2, "EUR", 9495)
        self.assertEqual((read["qty"], read["price_cents"]), ("2", 9495))
        page.goto("https://tienda-tres.example/pedido")
        # «Total a pagar», never «Subtotal», «Gastos de envío» or «Ahorras».
        self.assertEqual(engine.errand_total(self.js.evaluate)["text"], "193,89 €")

    def test_other_checkouts_say_their_total_their_own_way(self):
        shop = shops.ShopifyLike()
        shop.cart = [{"variant_id": 1002, "quantity": 1}]
        page = self.open(shop)
        page.goto("https://tienda-uno.example/checkout")
        self.assertEqual(engine.errand_total(self.js.evaluate)["text"], "39,94 €")
        woo = shops.WooLike()
        woo.cart = [{"id": 312, "quantity": 2}]
        page = self.open(woo)
        page.goto("https://tienda-dos.example/finalizar-compra/")
        self.assertEqual(engine.errand_total(self.js.evaluate)["text"], "65,80 €")

    def test_a_basket_without_the_product_says_where_the_cart_is(self):
        page = self.open(shops.Generic())
        page.goto("https://tienda-tres.example/p/calcetines-trail")
        with self.assertRaisesRegex(ValueError, "/cesta"):
            engine.errand_cart(self.js.evaluate, "Zapatillas Trail X", "43", 1, "EUR", 9495)


class FixtureProbe:
    """purchase_prices.Probe's surface over a jsdom page: a fresh basket per probe, as a
    disposable browser context has."""
    router = None

    def __init__(self, home):
        for shop in self.router.shops.values():
            shop.cart, shop.coupon = [], ""
        self.js = shops.JsPage(self.router)

    def goto(self, url):
        self.js.goto(prices.https(url))
        if not prices.same_site(self.js.url(), url):
            raise ValueError('La tienda redirigió a otro origen.')

    def evaluate(self, script):
        return self.js.evaluate(script)

    def sleep(self, seconds):
        pass

    def close(self):
        self.js.close()


@unittest.skipUnless(JSDOM, "node with jsdom is needed")
class PurchaseServiceTests(unittest.TestCase):
    """The chat's tools on any shop: shop + query in, cards out, no selector anywhere."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.shop = shops.Generic()
        FixtureProbe.router = shops.Router(self.shop, shops.ShopifyLike(), shops.WooLike())
        patch = mock.patch.object(prices, "https", side_effect=lambda url: url)
        patch.start()
        self.addCleanup(patch.stop)

    def test_discover_verify_and_cards_on_a_shop_nobody_wrote_an_adapter_for(self):
        search = prices.discover(self.home, "chat", {"shop": "tienda-dos.example", "query": "proteína whey"}, factory=FixtureProbe)
        self.assertEqual([c["title"] for c in search["candidates"]], ["Proteína Whey Isolate"])
        quote = prices.verify(self.home, "chat", {"search_id": search["id"], "candidate_id": search["candidates"][0]["id"],
                                                  "currency": "EUR", "variant": "Chocolate"}, factory=FixtureProbe)
        self.assertEqual((quote["price"], quote["variant"], quote["basis"]), ("32,90 €", "Chocolate", "cart"))
        shown = prices.auto_present(self.home, "chat", search["id"], currency="EUR", request="Compra proteína whey")
        self.assertTrue(shown and shown["ok"], shown)
        self.assertEqual(shown["options"][0]["price"], "32,90 €")

    def test_a_page_price_quote_still_gives_cards_and_says_it_is_confirmed_later(self):
        class NoButton(shops.Generic):
            def request(self, method, url, body=""):
                status, ctype, text, headers = super().request(method, url, body)
                return status, ctype, text.replace("Añadir a la cesta", "Ver tiendas"), headers
        FixtureProbe.router = shops.Router(NoButton())
        search = prices.discover(self.home, "chat", {"url": "https://tienda-tres.example/p/calcetines-trail"}, factory=FixtureProbe)
        quote = prices.verify(self.home, "chat", {"search_id": search["id"], "candidate_id": search["candidates"][0]["id"],
                                                  "currency": "EUR"}, factory=FixtureProbe)
        self.assertEqual((quote["price"], quote["basis"]), ("12,50 €", "page"))
        self.assertIn("se confirma", quote["condition"].lower().replace("lo confirma", "se confirma"))

    def test_the_errands_cart_check_and_total_need_no_selector(self):
        errands, flow = load("errands"), load("purchase_flow")
        self.shop.cart = [{"slug": "zapatillas-trail-x", "size": "43", "qty": 2}]
        offer = {"option_id": "x-1", "title": "Zapatillas Trail X", "variant": "Talla 43", "qty": 2, "price": "94,95 €",
                 "currency": "EUR", "url": "https://tienda-tres.example/p/zapatillas-trail-x", "quote_ref": "pq-x"}
        entry = errands.create(self.home, "Comprar zapatillas", offer=offer)
        js = shops.JsPage(shops.Router(self.shop))
        self.addCleanup(js.close)
        js.goto("https://tienda-tres.example/cesta")
        context = {"context": "ctx-1", "target": "t-1"}
        inspect = lambda e: ("https://tienda-tres.example", context, lambda method, params: {"cookies": []})
        evaluate = lambda ctx, code: js.evaluate(code)
        checked = prices.check_cart(self.home, entry["id"], {}, inspect=inspect, evaluate=evaluate)
        self.assertTrue(checked["ok"], checked)
        self.assertEqual(checked["price"], "94,95 €")
        js.goto("https://tienda-tres.example/pedido")
        total = prices.checkout_amount(errands.get(self.home, entry["id"]), "", inspect=inspect, evaluate=evaluate)
        self.assertEqual(total, "193,89 €")
        # On a page with no total the agent is told where to go, never handed a guess.
        js.goto("https://tienda-tres.example/p/calcetines-trail")
        with self.assertRaisesRegex(ValueError, "Total"):
            prices.checkout_amount(errands.get(self.home, entry["id"]), "", inspect=inspect, evaluate=evaluate)

    def test_wrong_units_in_the_errands_basket_never_reach_approval(self):
        errands = load("errands")
        self.shop.cart = [{"slug": "zapatillas-trail-x", "size": "43", "qty": 1}]
        offer = {"option_id": "x-1", "title": "Zapatillas Trail X", "variant": "Talla 43", "qty": 2, "price": "94,95 €",
                 "currency": "EUR", "url": "https://tienda-tres.example/p/zapatillas-trail-x", "quote_ref": "pq-x"}
        entry = errands.create(self.home, "Comprar zapatillas", offer=offer)
        js = shops.JsPage(shops.Router(self.shop))
        self.addCleanup(js.close)
        js.goto("https://tienda-tres.example/cesta")
        inspect = lambda e: ("https://tienda-tres.example", {"context": "c", "target": "t"}, lambda m, p: {"cookies": []})
        with self.assertRaisesRegex(ValueError, "unidades"):
            prices.check_cart(self.home, entry["id"], {}, inspect=inspect, evaluate=lambda ctx, code: js.evaluate(code))


if __name__ == "__main__":
    unittest.main()
