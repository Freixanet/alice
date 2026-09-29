"""The plugin's hooks around errands: a card is filled only for an approved checkout, a saved
login is used silently, and ask_person inside an errand reaches the person through the errand.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PLUGIN_INIT = Path(__file__).resolve().parents[1] / "__init__.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("hermes_plugin_alice_errand_hooks_test", PLUGIN_INIT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Meta(types.SimpleNamespace):
    pass


class ErrandHookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plugin = load_plugin()
        cls.errands = cls.plugin._errands()

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.metas = {"card": Meta(kind="payment", origin="https://www.hsnstore.com", label="Visa ···4242"),
                      "login": Meta(kind="login", origin="https://www.hsnstore.com", label="HSN")}
        store = types.SimpleNamespace(get_meta=lambda handle: self.metas.get(handle))
        cards = types.SimpleNamespace(_store=lambda: store, PAYMENT_GATEWAYS={"sis.redsys.es"})
        for patch in (
            mock.patch.object(self.plugin, "_hermes_root", return_value=self.home),
            mock.patch.object(self.errands, "_fetch", side_effect=OSError("offline")),
            mock.patch.object(self.plugin, "_cards_module", return_value=cards),
            mock.patch.object(self.plugin, "_open_tabs", return_value=["https://www.hsnstore.com/checkout"]),
            mock.patch.object(self.plugin, "_active_url", return_value="https://www.hsnstore.com/checkout/step/payment/"),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def errand(self, **kwargs):
        return self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure", **kwargs)

    def test_a_card_fill_needs_the_approved_checkout(self):
        entry = self.errand()
        fill = {"handle": "card"}
        verdict = self.plugin._guard_errand("browser_vault_fill", fill, session_id=entry["session_id"])
        self.assertEqual(verdict["action"], "block")
        self.errands.request_checkout(self.home, entry["id"], {"merchant": "HSN", "site": "hsnstore.com",
                                                               "items": [{"name": "Creatina"}], "total": "27,98 €"})
        self.errands.decide_checkout(self.home, entry["id"], True)
        self.assertIsNone(self.plugin._guard_errand("browser_vault_fill", fill, session_id=entry["session_id"]))

    def test_a_chat_is_told_to_start_an_errand(self):
        verdict = self.plugin._guard_errand("browser_vault_fill", {"handle": "card"}, session_id="20260922_155237_281345")
        self.assertIn("errand_start", verdict["message"])
        # Browsing that pays nothing is fine in a chat.
        self.assertIsNone(self.plugin._guard_errand("browser_exec", {"code": "print(page_info())"},
                                                    session_id="20260922_155237_281345"))

    def test_a_click_on_the_payment_step_is_held(self):
        entry = self.errand()
        verdict = self.plugin._guard_errand("browser_exec", {"code": "click_at_xy(400,508)"},
                                            session_id=entry["session_id"])
        self.assertEqual(verdict["action"], "block")

    def test_a_saved_login_goes_in_silently_unless_asked(self):
        quiet = self.errand()
        self.assertIsNone(self.plugin._guard_errand("browser_vault_fill", {"handle": "login"},
                                                    session_id=quiet["session_id"]))
        careful = self.errand(ask_before_login=True)
        verdict = self.plugin._guard_errand("browser_vault_fill", {"handle": "login"}, session_id=careful["session_id"])
        self.assertEqual(verdict["action"], "approve")

    def test_if_the_check_fails_no_card_is_filled(self):
        entry = self.errand()
        with mock.patch.object(self.plugin, "_cards_module", side_effect=RuntimeError("vault locked")):
            verdict = self.plugin._guard_errand("browser_vault_fill", {"handle": "card"}, session_id=entry["session_id"])
        self.assertEqual(verdict["action"], "block")

    def test_an_errand_step_is_the_comment_on_the_browser_code(self):
        entry = self.errand()
        self.plugin._errand_step("browser_exec", {"code": "# Abrir la ficha de la creatina\ngoto_url('x')"},
                                 entry["session_id"])
        self.plugin._errand_step("browser_exec", {"code": "print(1)"}, entry["session_id"])
        self.plugin._errand_step("browser_exec", {"code": "# En un chat no cuenta"}, "chat-1")
        steps = self.errands.get(self.home, entry["id"])["steps"]
        self.assertEqual([s["text"] for s in steps], ["Abrir la ficha de la creatina"])

    def test_the_checkout_tool_only_works_inside_an_errand(self):
        registered = {}
        ctx = types.SimpleNamespace(register_tool=lambda **kw: registered.__setitem__(kw["name"], kw))
        self.plugin._register_task_tools(ctx)
        self.assertEqual(set(registered), {"errand_start", "checkout_request", "card_request"})
        handler = registered["checkout_request"]["handler"]
        with mock.patch.object(self.plugin, "_session_id", return_value="chat-1"):
            self.assertFalse(json.loads(handler({"merchant": "HSN"}))["ok"])
        entry = self.errand()
        with mock.patch.object(self.plugin, "_session_id", return_value=entry["session_id"]):
            out = json.loads(handler({"merchant": "HSN", "site": "hsnstore.com", "items": [{"name": "Creatina"}],
                                      "total": "27,98 €"}))
        self.assertTrue(out["ok"])
        self.assertEqual(self.errands.get(self.home, entry["id"])["status"], "needs_approval")


    def test_a_chat_turn_that_asks_to_buy_neither_browses_nor_asks(self):
        with mock.patch.object(self.errands, "launch", return_value=True), \
                mock.patch.object(self.errands, "open_goal"), \
                mock.patch.object(self.plugin, "_root_and_sender", return_value=(self.home, "default")):
            note = self.plugin._errand_turn(session_id="chat-9", user_message="compra un iphone 18 pro max")
            # Started by the plugin itself, once: asking again gets the same errand.
            again = self.plugin._errand_turn(session_id="chat-9", user_message="compra un iphone 18 pro max")
        started = [e for e in self.errands.listing(self.home) if e["origin_session"] == "chat-9"]
        self.assertEqual(len(started), 1)
        self.assertIn(started[0]["id"], note["context"])
        self.assertEqual(note["context"], again["context"])
        for tool in ("browser_exec", "browser_navigate", "ask_person"):
            self.assertEqual(self.plugin._guard_chat_errand(tool, session_id="chat-9")["action"], "block")
        self.assertIsNone(self.plugin._guard_chat_errand("errand_start", session_id="chat-9"))
        # The next turn about something else browses again.
        self.assertIsNone(self.plugin._errand_turn(session_id="chat-9", user_message="dame los titulares de HN"))
        self.assertIsNone(self.plugin._guard_chat_errand("browser_exec", session_id="chat-9"))
        # Inside an errand nothing changes.
        entry = self.errand()
        self.assertIsNone(self.plugin._errand_turn(session_id=entry["session_id"], user_message="compra"))

if __name__ == "__main__":
    unittest.main()
