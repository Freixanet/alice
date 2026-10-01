"""A purchase in the chat (steps 1–6): only what can be bought is shown, and only a shown option is bought.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "purchase_flow.py"
spec = importlib.util.spec_from_file_location("alice_purchase_flow_test", PATH)
flow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)

NOW = 1_800_000_000.0


def option(**kw):
    base = {"title": "Creatina Excell 500 g", "merchant": "HSN", "variant": "Sin sabor", "price": "27,98 €",
            "currency": "EUR", "url": "https://www.hsnstore.com/creatina", "in_stock": True, "channel": "browser",
            "image": "https://www.hsnstore.com/c.jpg"}
    return {**base, **kw}


class VerifyTests(unittest.TestCase):
    def test_price_currency_cannot_contradict_the_option_currency(self):
        kept, discarded = flow.verify([option(price='$27.98', currency='EUR')])
        self.assertFalse(kept)
        self.assertEqual(len(discarded), 1)

    def test_only_what_can_be_bought_is_kept_and_the_rest_says_why(self):
        kept, discarded = flow.verify([
            option(),
            option(title="Sin página", url="http://x.example/p"),
            option(title="Sin precio", price="consultar"),
            option(title="En dólares", currency="USD", price="$20"),
            option(title="Agotada", in_stock=False),
            option(title="Sin comprobar", in_stock="yes"),
        ], currency="EUR")
        self.assertEqual([o["title"] for o in kept], ["Creatina Excell 500 g"])
        self.assertEqual([d["title"] for d in discarded],
                         ["Sin página", "Sin precio", "En dólares", "Agotada", "Sin comprobar"])

    def test_an_options_id_is_its_sets_key_and_position(self):
        options = [option(), option(title="Otra", url="https://www.prozis.com/c")]
        kept, _ = flow.verify(options)
        key = flow.set_key(options)
        self.assertEqual([o["id"] for o in kept], [f"{key}-1", f"{key}-2"])
        # The app computes the key from the same pages, one per line.
        import hashlib
        import json
        rows = [[o["url"], o["variant"], "1", o["price"], o["currency"]] for o in options]
        self.assertEqual(key, hashlib.sha256(json.dumps(
            rows, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()[:8])
        self.assertNotEqual(flow.set_key([option(variant="Limón")]), flow.set_key([option()]))

    def test_one_recommendation_at_most_and_a_missing_picture_is_looked_for(self):
        kept, _ = flow.verify([option(recommended=True, image=""), option(url="https://b.example/p", recommended=True)],
                              picture=lambda page: "https://b.example/og.jpg")
        self.assertEqual([o["recommended"] for o in kept], [True, False])
        self.assertEqual(kept[0]["image"], "https://b.example/og.jpg")


class StoreTests(unittest.TestCase):
    def test_requested_brand_is_kept_without_padding_with_another_brand(self):
        prozis = option(merchant="Prozis", title="Creatina Creapure 300 g", url="https://www.prozis.com/p")
        other = option(merchant="Body&Fit", title="Creapure Creatine 500 g", url="https://www.bodyandfit.com/p")
        out = flow.present(self.home, "chat-1", {"options": [prozis, other]},
                           request="Compra la creatina creapure de prozis", now=NOW)
        self.assertTrue(out["ok"])
        self.assertEqual([o["title"] for o in out["options"]], ["Creatina Creapure 300 g"])
        self.assertIn("prozis", out["discarded"][0]["why"])
        self.assertTrue(flow.present(self.home, "chat-1", {"options": [prozis]},
                                     request="Compra la creatina de Prozis", now=NOW)["ok"])
        self.assertFalse(flow.present(self.home, "chat-1", {"options": [other]},
                                      request="Compra la creatina de Prozis", now=NOW)["ok"])

    def test_brand_request_survives_restart_and_is_scoped_to_the_chat(self):
        flow.remember_request(self.home, "chat-1", "Compra zapatillas marca New Balance", now=NOW)
        self.assertEqual(flow.saved_request(self.home, "chat-1", now=NOW+1), "Compra zapatillas marca New Balance")
        self.assertEqual(flow.saved_request(self.home, "chat-2", now=NOW+1), "")
        self.assertEqual(flow.saved_request(self.home, "chat-1", now=NOW+flow.KEEP+1), "")
        nb = option(merchant="New Balance", title="Zapatillas", url="https://www.newbalance.com/p")
        other = option(merchant="Adidas", title="Zapatillas", url="https://www.adidas.com/p")
        out = flow.present(self.home, "chat-1", {"options": [nb, other]}, now=NOW+1)
        self.assertEqual(len(out["options"]), 1)

    def test_other_brands_are_allowed_only_when_the_request_asks_for_alternatives(self):
        values = [option(merchant="Prozis"), option(merchant="Body&Fit", url="https://b.example/p")]
        out = flow.present(self.home, "chat-1", {"options": values},
                           request="Compra creatina de Prozis o alternativas de otras marcas", now=NOW)
        self.assertEqual(len(out["options"]), 2)
        out = flow.present(self.home, "chat-1", {"options": values},
                           request="Compra creatina de Prozis, no otras marcas", now=NOW)
        self.assertEqual(len(out["options"]), 1)

    def test_invalid_remembered_basket_price_is_not_shown_or_allowed_to_crash(self):
        for price in ('consultar', '$27.98'):
            with self.subTest(price=price):
                out = flow.present(self.home, 'chat-1', {'options': [option()]}, now=NOW,
                                   exact_item=True, known_prices={'https://www.hsnstore.com/creatina': price})
                self.assertFalse(out['ok'])
                self.assertTrue(out['discarded'])

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

    def test_shown_options_are_chosen_only_in_their_chat(self):
        out = flow.present(self.home, "chat-1", {"options": [option()]}, currency="EUR", now=NOW, exact_item=True)
        chosen_id = out["options"][0]["id"]
        self.assertTrue(flow.open_options(self.home, "chat-1", now=NOW))
        self.assertIsNone(flow.choose(self.home, "chat-2", chosen_id))
        picked = flow.choose(self.home, "chat-1", chosen_id)
        self.assertEqual(picked["url"], "https://www.hsnstore.com/creatina")
        self.assertEqual(flow.options_set(self.home, chosen_id.split("-")[0])["chosen"], chosen_id)
        self.assertFalse(flow.open_options(self.home, "chat-1", now=NOW))

    def test_same_pages_in_two_chats_keep_independent_choices(self):
        args = {"options": [option()]}
        first = flow.present(self.home, "chat-1", args, now=NOW, exact_item=True)
        flow.present(self.home, "chat-2", args, now=NOW, exact_item=True)
        choice = first["options"][0]["id"]
        self.assertIsNotNone(flow.choose(self.home, "chat-1", choice, now=NOW))
        key = choice.split("-")[0]
        self.assertEqual(flow.options_set(self.home, key, "chat-1", now=NOW)["chosen"], choice)
        self.assertIsNone(flow.options_set(self.home, key, "chat-2", now=NOW)["chosen"])
        self.assertIsNone(flow.options_set(self.home, key, now=NOW))

    def test_expired_options_cannot_be_read_or_chosen(self):
        first = flow.present(self.home, "chat-1", {"options": [option()]}, now=NOW, exact_item=True)
        choice = first["options"][0]["id"]
        later = NOW + flow.KEEP + 1
        self.assertIsNone(flow.choose(self.home, "chat-1", choice, now=later))
        self.assertIsNone(flow.options_set(self.home, choice.split("-")[0], "chat-1", now=later))

    def test_nothing_verifiable_is_not_shown_and_says_how_to_go_on(self):
        out = flow.present(self.home, "chat-1", {"options": [option(in_stock=False)]}, now=NOW, exact_item=True)
        self.assertFalse(out["ok"])
        self.assertIn("propón", out["error"])
        self.assertEqual(out["discarded"][0]["why"], "sin stock comprobado")
        # The app finds an empty set and draws nothing, instead of «these options are gone».
        key = flow.set_key([option(in_stock=False)])
        self.assertEqual(flow.options_set(self.home, key)["options"], [])

    def test_old_sets_are_forgotten(self):
        flow.present(self.home, "chat-1", {"options": [option()]}, now=NOW, exact_item=True)
        flow.present(self.home, "chat-1", {"options": [option(url="https://b.example/p")]}, now=NOW + flow.KEEP + 1,
                     exact_item=True)
        self.assertEqual(len(flow._read(flow._path(self.home))), 1)


class WordsTests(unittest.TestCase):
    def test_a_purchase_request(self):
        for text in ("compra un iphone 18 pro max", "Pídeme el pienso de siempre", "buy a lamp",
                     "añádelo al carrito"):
            self.assertTrue(flow.is_purchase_request(text), text)
        for text in ("abre news.ycombinator.com y dame 3 titulares", "[respuesta:size] 256 GB",
                     "[elección:a1b2c3d4-1] Creatina", "Resérvame la ITV"):
            self.assertFalse(flow.is_purchase_request(text), text)

    def test_a_tapped_choice(self):
        self.assertEqual(flow.chosen_id("[elección:a1b2c3d4-2] Creatina · HSN · 27,98 €"), "a1b2c3d4-2")
        self.assertEqual(flow.chosen_id("[eleccion:a1b2c3d4-1] x"), "a1b2c3d4-1")
        self.assertEqual(flow.chosen_id("@compras [elección:a1b2c3d4-2] Producto"), "a1b2c3d4-2")
        self.assertIsNone(flow.chosen_id("la segunda"))

    def test_a_cart_action_is_told_apart_from_reading(self):
        self.assertTrue(flow.is_cart_action("browser_click", {"text": "Añadir a la cesta"}))
        self.assertTrue(flow.is_cart_action("browser_exec", {"code": "click('Add to bag')"}))
        self.assertFalse(flow.is_cart_action("browser_exec", {"code": "print(page_info())"}))
        self.assertFalse(flow.is_cart_action("browser_navigate", {"url": "https://x/cart"}))

    def test_the_context_says_what_is_known_and_never_asks_country_or_currency(self):
        block = flow.context_block({"city": "Súria", "postcode": "08260", "country": "España", "currency": "Euro"},
                                   [{"label": "Visa ···4242"}],
                                   [{"merchant": "HSN", "card_label": "Visa ···4242"}])
        for part in ("país: ES", "moneda: EUR", "Súria", "HSN", "Visa ···4242", "la última usada",
                     "No le preguntes país ni moneda"):
            self.assertIn(part, block)
        self.assertNotIn("ask_person", block)
        # Nothing kept: Hermes' own time zone says where the person is.
        self.assertIn("país: ES", flow.context_block({}, [], [], timezone="Europe/Madrid"))

    def test_country_and_currency_are_deduced_and_names_are_codes(self):
        self.assertEqual(flow.locale({"country": "España", "currency": "Euro"}), ("ES", "EUR"))
        self.assertEqual(flow.locale({}, "Europe/Madrid"), ("ES", "EUR"))
        self.assertEqual(flow.locale({"country": "uk"}), ("GB", "GBP"))
        self.assertEqual(flow.locale({}, "Pacific/Nowhere"), ("", ""))
        self.assertEqual((flow.iso_currency("€"), flow.iso_currency("eur"), flow.iso_currency("xx")), ("EUR", "EUR", ""))

    def test_a_currency_written_as_a_word_is_not_a_reason_to_drop_an_option(self):
        # «Euro» kept from a card: the 80-capsule Creapure at 20,99 € was dropped as «not in EURO».
        kept, discarded = flow.verify([option(currency="EUR"), option(url="https://b.example/p", currency="€")],
                                      currency="Euro")
        self.assertEqual((len(kept), discarded), (2, []))
        self.assertEqual({o["currency"] for o in kept}, {"EUR"})

    def test_questions_during_a_purchase(self):
        self.assertIn("país ni moneda", flow.ask_refusal([{"id": "c", "question": "País", "field": "country"}], True))
        priced = [{"id": "f", "question": "¿Cuál?", "choices": ["80 cápsulas · 20,99 €", "300 g · 24,49 €"]}]
        self.assertIn("purchase_options", flow.ask_refusal(priced, True))
        guessed = [{"id": "f", "question": "¿Qué formato?", "choices": ["500 g", "1 kg"]}]
        self.assertIn("no has mirado", flow.ask_refusal(guessed, looked=False))
        self.assertIn("purchase_options", flow.ask_refusal(guessed, looked=True))
        substitution = [{'question': 'En la tienda oficial solo encuentro MicronPure, no Creapure. ¿Te vale esa?',
                         'choices': ['Me vale MicronPure de Prozis', 'Busca Creapure de otra marca']}]
        self.assertIn('categoría completa', flow.ask_refusal(substitution, looked=True))
        self.assertIsNone(flow.ask_refusal([{"id": "q", "question": "¿Para quién es?"}], looked=False))

    def test_the_errand_gets_the_exact_offer(self):
        kept, _ = flow.verify([option(qty=2)])
        offer = flow.offer(kept[0])
        self.assertEqual((offer["option_id"], offer["qty"], offer["variant"]), (kept[0]["id"], 2, "Sin sabor"))
        self.assertIn("https://www.hsnstore.com/creatina", flow.task(kept[0]))
        self.assertEqual(flow.title(kept[0]), "Comprar Creatina Excell 500 g en HSN")



class OptionsCountTests(unittest.TestCase):
    def test_a_single_card_needs_a_reason(self):
        home = Path(tempfile.mkdtemp())
        # Prozis had four formats and the catalog more; one card left the person nothing to choose.
        out = flow.present(home, "chat-1", {"options": [option()], "only_one": "es el que más sentido tiene"}, now=NOW)
        self.assertFalse(out["ok"], "a preference is not a reason to hide the other options")
        self.assertIn("al menos dos", out["error"])
        # An exact item the person linked may be one card.
        self.assertTrue(flow.present(home, "chat-1", {"options": [option()]}, now=NOW, exact_item=True)["ok"])

    def test_a_price_the_basket_contradicted_is_not_offered_again(self):
        home = Path(tempfile.mkdtemp())
        out = flow.present(home, "chat-1", {"options": [option(price="24,49 €"), option(url="https://b.example/p")]},
                           now=NOW, known_prices={"https://www.hsnstore.com/creatina": "34,99 €"})
        self.assertEqual(out["adjusted"], [{"title": "Creatina Excell 500 g", "shown": "24,49 €", "real": "34,99 €"}])
        self.assertEqual(out["options"][0]["price"], "34,99 €")
        self.assertIn("34,99 €", out["next"])
        self.assertTrue(flow.present(home, "chat-1", {"options": [option(), option(url="https://b.example/p")]},
                                     now=NOW)["ok"])

class AppKeyTests(unittest.TestCase):
    def test_the_key_is_the_apps_even_with_a_number_price_or_a_text_quantity(self):
        # The value PurchaseOptionSet.key gives in the app for these same arguments.
        options = [
            {"url": "https://www.hsnstore.com/creatina ", "variant": "Sin sabor / Limón", "qty": 2,
             "price": "27,98 €", "currency": "EUR"},
            {"url": "https://b.example/p?x=1&y=ñ", "price": "19.99", "currency": "EUR"},
            {"url": "https://c.example/p", "price": 27.98, "currency": "EUR", "qty": "3"},
        ]
        self.assertEqual(flow.set_key(options), "e0cad1a7")


class SharedKeyVectorTests(unittest.TestCase):
    """The same fixture the iOS suite reads (PurchaseOptionsKeyTests): drift fails a test, not the cards."""

    def test_every_shared_vector(self):
        fixture = json.loads((Path(__file__).resolve().parent / "fixtures" / "option_keys.json").read_text("utf-8"))
        self.assertGreaterEqual(len(fixture["vectors"]), 5)
        for vector in fixture["vectors"]:
            self.assertEqual(flow.set_key(vector["options"]), vector["key"], vector["name"])

if __name__ == "__main__":
    unittest.main()
