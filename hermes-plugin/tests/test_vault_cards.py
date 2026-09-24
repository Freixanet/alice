"""Cards given in Alice's secure card land in Hermes' vault, bound to one payment page.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import datetime
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "vault_cards.py"
spec = importlib.util.spec_from_file_location("alice_vault_cards_test", PATH)
cards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cards)

try:
    from agent.vault_store import VaultStore
except ImportError:  # pragma: no cover - Hermes not on the path
    VaultStore = None

VISA = "4242 4242 4242 4242"
TODAY = datetime.date(2026, 9, 24)


class CleanCardTests(unittest.TestCase):
    def test_a_valid_card_uses_hermes_field_names(self):
        payload = cards.clean_card({"card_number": VISA, "exp_month": "3", "exp_year": "29", "cvc": "123",
                                    "cardholder_name": "  Ana   Pérez "}, today=TODAY)
        self.assertEqual(payload, {"card_number": "4242424242424242", "exp_month": "03", "exp_year": "2029",
                                   "cvc": "123", "cardholder_name": "Ana Pérez"})

    def test_a_mistyped_number_is_refused(self):
        with self.assertRaises(cards.CardError):
            cards.clean_card({"card_number": "4242 4242 4242 4241", "exp_month": "3", "exp_year": "29",
                              "cvc": "123"}, today=TODAY)

    def test_an_expired_card_is_refused(self):
        with self.assertRaises(cards.CardError):
            cards.clean_card({"card_number": VISA, "exp_month": "8", "exp_year": "2026", "cvc": "123"},
                             today=TODAY)

    def test_the_code_is_three_or_four_digits(self):
        with self.assertRaises(cards.CardError):
            cards.clean_card({"card_number": VISA, "exp_month": "3", "exp_year": "29", "cvc": "12"},
                             today=TODAY)

    def test_errors_never_carry_the_number(self):
        try:
            cards.clean_card({"card_number": "4242424242424241"}, today=TODAY)
        except cards.CardError as exc:
            self.assertNotIn("4242", str(exc))


@unittest.skipIf(VaultStore is None, "Hermes is not on the path")
class VaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = VaultStore(Path(self.tmp.name) / "vault")
        patcher = mock.patch.object(cards, "_store", return_value=self.store)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)
        self.card = {"card_number": VISA, "exp_month": "03", "exp_year": "2031", "cvc": "123"}

    def test_a_card_is_bound_to_the_payment_page_and_shows_only_its_label(self):
        saved = cards.save("https://sis.redsys.es/sis/realizarPago?x=1", self.card)
        self.assertEqual(saved["label"], "Visa ···4242")
        self.assertEqual(saved["origin"], "https://sis.redsys.es")
        self.assertEqual(cards.cards(), [saved])
        self.assertNotIn("4242424242424242", repr(cards.cards()))

    def test_a_shop_card_also_works_on_its_www_twin_and_is_removed_from_both(self):
        saved = cards.save("https://piensosraposo.es", self.card)
        self.assertEqual(sorted(c["origin"] for c in cards.cards()),
                         ["https://piensosraposo.es", "https://www.piensosraposo.es"])
        self.assertTrue(cards.remove(saved["handle"]))
        self.assertEqual(cards.cards(), [])

    def test_a_fill_goes_to_the_card_for_the_page_actually_open(self):
        shop = cards.save("https://piensosraposo.es", self.card)
        www = [c for c in cards.cards() if c["origin"] == "https://www.piensosraposo.es"][0]
        # The shop's checkout on www: the www copy, not the bare one.
        self.assertEqual(cards.route_fill(shop["handle"], ["https://www.piensosraposo.es/pedido"]), www["handle"])
        # Sent to Redsys: the card is bound there and that copy used.
        routed = cards.route_fill(shop["handle"], ["https://www.piensosraposo.es/pedido",
                                                   "https://sis.redsys.es/sis/realizarPago"])
        self.assertEqual(self.store.get_meta(routed).origin, "https://sis.redsys.es")
        # Any other site: left alone (Hermes refuses it).
        self.assertIsNone(cards.route_fill(shop["handle"], ["https://evil.example/pay"]))

    def test_twins(self):
        self.assertEqual(cards.twins("https://www.shop.es"), ["https://www.shop.es", "https://shop.es"])
        self.assertEqual(cards.twins("https://sis.redsys.es"), ["https://sis.redsys.es"])

    def test_only_https_pages(self):
        with self.assertRaises(cards.CardError):
            cards.save("http://shop.example", self.card)

    def test_saving_the_same_card_again_replaces_it(self):
        cards.save("https://sis.redsys.es", self.card)
        cards.save("https://sis.redsys.es", {**self.card, "cvc": "456"})
        self.assertEqual(len(cards.cards()), 1)
        handle = cards.cards()[0]["handle"]
        self.assertEqual(self.store.resolve_secret(handle)["cvc"], "456")

    def test_a_saved_card_can_be_used_on_another_page_without_typing_it(self):
        first = cards.save("https://sis.redsys.es", self.card)
        other = cards.bind(first["handle"], "https://pay.example.com")
        self.assertEqual(other["origin"], "https://pay.example.com")
        self.assertEqual(self.store.resolve_secret(other["handle"]),
                         self.store.resolve_secret(first["handle"]))
        self.assertEqual(cards.bind(first["handle"], "https://pay.example.com"), other)

    def test_logins_are_not_cards(self):
        login = self.store.add_item(kind="login", label="shop", origin="https://shop.example",
                                    secret={"identifier_type": "email", "identifier": "a@b.c", "password": "x"})
        self.assertEqual(cards.cards(), [])
        self.assertFalse(cards.remove(login.id))
        with self.assertRaises(cards.CardError):
            cards.bind(login.id, "https://sis.redsys.es")

    def test_remove(self):
        saved = cards.save("https://sis.redsys.es", self.card)
        self.assertTrue(cards.remove(saved["handle"]))
        self.assertEqual(cards.cards(), [])


class PromptTests(unittest.TestCase):
    def test_the_link_names_the_profile_and_the_chat_never_carries_the_card(self):
        text = cards.prompt("default")
        self.assertIn("alice://connect/card?origin=ORIGEN&profile=default", text)
        self.assertIn("nunca pidas los datos en el chat", text)
        # Hermes' card confirmation is the one yes; the agent does not ask again in the chat.
        self.assertIn("es el sí de la compra", text)


if __name__ == "__main__":
    unittest.main()
