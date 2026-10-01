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
        self.plugin._ERRAND_TURN_IDS.clear()
        self.plugin._AUTOMATED_TURNS.clear()
        self.plugin._PURCHASE_OPEN.clear()
        self.plugin._PURCHASE_REQUESTS.clear()
        self.plugin._LOOKED.clear()
        self.metas = {"card": Meta(kind="payment", origin="https://www.hsnstore.com", label="Visa ···4242"),
                      "login": Meta(kind="login", origin="https://www.hsnstore.com", label="HSN")}
        store = types.SimpleNamespace(get_meta=lambda handle: self.metas.get(handle))
        cards = types.SimpleNamespace(_store=lambda: store, PAYMENT_GATEWAYS={"sis.redsys.es"},
                                      cards=lambda: [{"label": "Visa ···4242"}])
        self.flow = self.plugin._purchase_flow()
        for patch in (
            mock.patch.object(self.plugin, "_hermes_root", return_value=self.home),
            mock.patch.object(self.errands, "_fetch", side_effect=OSError("offline")),
            mock.patch.object(self.plugin, "_cards_module", return_value=cards),
            mock.patch.object(self.plugin, "_open_tabs", return_value=["https://www.hsnstore.com/checkout"]),
            mock.patch.object(self.plugin, "_active_url", return_value="https://www.hsnstore.com/checkout/step/payment/"),
            mock.patch.object(self.plugin, "_purchase_context", return_value="[Alice · compra] Lo que sé — país: ES."),
            mock.patch.object(self.plugin, "_root_and_sender", return_value=(self.home, "default")),
            mock.patch.object(self.errands, "launch", return_value=True),
            mock.patch.object(self.errands, "open_goal"),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def errand(self, **kwargs):
        return self.errands.create(self.home, "Compra la creatina", title="Comprar Creapure", **kwargs)

    def tools(self):
        registered = {}
        ctx = types.SimpleNamespace(register_tool=lambda **kw: registered.__setitem__(kw["name"], kw))
        self.plugin._register_task_tools(ctx)
        return registered

    def test_purchase_cannot_bypass_approval_with_execution_tools(self):
        entry = self.errand(offer={"option_id":"chosen", "price":"34,99 €"})
        for tool in ("terminal", "execute_code", "browser_eval", "browser_evaluate"):
            with self.subTest(tool=tool):
                result = self.plugin._guard_errand(tool_name=tool, args={"command":"submit order"}, session_id=entry["session_id"])
                self.assertEqual(result["action"], "block")

    def test_execution_guard_preserves_non_purchase_sessions(self):
        entry = self.errand()
        self.assertIsNone(self.plugin._guard_errand(tool_name="terminal", args={}, session_id=entry["session_id"]))
        self.assertIsNone(self.plugin._guard_errand(tool_name="terminal", args={}, session_id="ordinary-chat"))

    def test_purchase_browser_code_cannot_use_raw_execution_or_transport(self):
        entry = self.errand(offer={"option_id":"chosen", "price":"34,99 €"})
        for code in ("import requests; requests.post('https://example.com/pay')", "open('vault')",
                     "__import__('os')", "browser._client.send('Runtime.evaluate', {})", "js('fetch(\"/pay\",{method:\"POST\"})')"):
            with self.subTest(code=code):
                result = self.plugin._isolate_errand_browser(tool_name="browser_exec", args={"code":code}, session_id=entry["session_id"])
                self.assertEqual(result["action"], "block")
        self.assertEqual(self.plugin._guard_errand(tool_name="browser_get_state", args={"expression":"submit()"}, session_id=entry["session_id"])["action"], "block")
        result = self.plugin._isolate_errand_browser(tool_name="browser_exec", args={"code":"print(page_info()); click(3)"}, session_id=entry["session_id"])
        self.assertEqual(result["action"], "modify")

    def test_resumed_purchase_protects_all_browser_outputs_and_fails_closed(self):
        entry = self.errand(offer={'url':'https://example.com/product'})
        self.errands.update(self.home,entry['id'],secure_answered='request-done')
        access = self.plugin._module('errand_access.py','alice_errand_access')
        with mock.patch.object(access,'protect_browser_secrets') as protect:
            for name in ('browser_exec','browser_get_state','browser_screenshot'):
                self.assertIsNone(self.plugin._guard_errand_access(name,{},session_id=entry['session_id']))
            self.assertEqual(protect.call_count,3)
        with mock.patch.object(access,'protect_browser_secrets',side_effect=ValueError('private failure')):
            result = self.plugin._guard_errand_access('browser_get_state',{},session_id=entry['session_id'])
            self.assertEqual(result['action'],'block')
            self.assertNotIn('private failure',result['message'])

    def shown(self, session="chat-9"):
        """Two verified options shown in `session`; their ids."""
        out = self.flow.present(self.home, session, {"options": [
            {"title": "Creatina Excell 500 g", "merchant": "HSN", "variant": "Sin sabor", "price": "27,98 €",
             "currency": "EUR", "url": "https://www.hsnstore.com/creatina", "in_stock": True, "channel": "browser",
             "image": "https://www.hsnstore.com/c.jpg", "recommended": True},
            {"title": "Creatina Creapure 300 g", "merchant": "Prozis", "price": "19,99 €", "currency": "EUR",
             "url": "https://www.prozis.com/creatina", "in_stock": True, "channel": "browser",
             "image": "https://www.prozis.com/c.jpg"},
        ]})
        prices = self.plugin._module("purchase_prices.py", "alice_purchase_prices")
        with self.flow._locked(self.home) as path:
            sets = self.flow._read(path)
            quotes = {}
            for found in sets:
                for option in found['options']:
                    ref = 'pq-fixture-' + option['id']
                    option['quote_ref'] = ref
                    quotes[ref] = {**option, 'id':ref, 'session':session, 'at':__import__('time').time()}
            self.flow._write(path,sets)
            prices._save(self.home,{'searches':{},'quotes':quotes})
        return [o["id"] for o in out["options"]]

    def call(self, handler, args, session="chat-9"):
        approval = types.SimpleNamespace(get_current_session_key=lambda **_: "run-1")
        with mock.patch.object(self.plugin, "_session_id", return_value=session), \
                mock.patch.dict(sys.modules, {"tools.approval_context": approval}):
            return json.loads(handler(args))

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

    def test_payment_guard_fails_closed_when_checking_approval_raises(self):
        entry=self.errand()
        with mock.patch.object(self.errands,'pay_gate',side_effect=RuntimeError('unavailable')):
            verdict=self.plugin._guard_errand('browser_click',{'text':'Pagar ahora'},session_id=entry['session_id'])
        self.assertEqual(verdict['action'],'block')

    def test_an_approved_purchase_still_requires_matching_live_total(self):
        entry=self.errand()
        self.errands.request_checkout(self.home,entry['id'],{'merchant':'HSN','site':'hsnstore.com','items':[{'name':'Creatina'}],'total':'27,98 €'})
        self.errands.decide_checkout(self.home,entry['id'],True)
        self.errands.update(self.home,entry['id'],offer={'quote_ref':'pq-test'})
        prices=self.plugin._module('purchase_prices.py','alice_purchase_prices')
        access=self.plugin._module('errand_access.py','alice_errand_access')
        with mock.patch.object(access,'target',return_value=('https://www.hsnstore.com',{'url':'https://www.hsnstore.com/checkout/step/payment/'},None)), mock.patch.object(prices,'payment_ready',return_value=False):
            verdict=self.plugin._guard_errand('browser_click',{'text':'Pagar ahora'},session_id=entry['session_id'])
        self.assertEqual(verdict['action'],'block')
        with mock.patch.object(access,'target',return_value=('https://www.hsnstore.com',{'url':'https://www.hsnstore.com/checkout/step/payment/'},None)), mock.patch.object(prices,'payment_ready',return_value=True):
            self.assertIsNone(self.plugin._guard_errand('browser_click',{'text':'Pagar ahora'},session_id=entry['session_id']))

    def test_coordinate_payment_uses_this_errands_page_not_another_tab(self):
        entry=self.errand()
        self.errands.update(self.home,entry['id'],offer={'quote_ref':'pq-test'})
        access=self.plugin._module('errand_access.py','alice_errand_access')
        with mock.patch.object(self.plugin,'_active_url',return_value='https://other.example/home'), mock.patch.object(access,'target',return_value=('https://www.hsnstore.com',{'url':'https://www.hsnstore.com/checkout/step/payment/'},None)):
            verdict=self.plugin._guard_errand('browser_exec',{'code':'click_at_xy(30,50)'},session_id=entry['session_id'])
        self.assertEqual(verdict['action'],'block')

    def test_an_errand_step_is_the_comment_on_the_browser_code(self):
        entry = self.errand()
        self.plugin._errand_step("browser_exec", {"code": "# Abrir la ficha de la creatina\ngoto_url('x')"},
                                 entry["session_id"])
        self.plugin._errand_step("browser_exec", {"code": "print(1)"}, entry["session_id"])
        self.plugin._errand_step("browser_exec", {"code": "# En un chat no cuenta"}, "chat-1")
        steps = self.errands.get(self.home, entry["id"])["steps"]
        self.assertEqual([s["text"] for s in steps], ["Abrir la ficha de la creatina"])

    def test_the_checkout_tool_only_works_inside_an_errand(self):
        registered = self.tools()
        self.assertEqual(set(registered), {"errand_start", "checkout_request", "card_request", "purchase_options",
                                           "catalog_search", "catalog_product", "login_request", "login_fill", "purchase_check_cart", "purchase_discover", "purchase_verify"})
        handler = registered["checkout_request"]["handler"]
        with mock.patch.object(self.plugin, "_session_id", return_value="chat-1"):
            self.assertFalse(json.loads(handler({"merchant": "HSN"}))["ok"])
        entry = self.errand()
        with mock.patch.object(self.plugin, "_session_id", return_value=entry["session_id"]):
            out = json.loads(handler({"merchant": "HSN", "site": "hsnstore.com", "items": [{"name": "Creatina"}],
                                      "total": "27,98 €"}))
        self.assertTrue(out["ok"])
        self.assertEqual(self.errands.get(self.home, entry["id"])["status"], "needs_approval")


    def test_a_purchase_request_starts_nothing_and_brings_the_persons_context(self):
        note = self.plugin._errand_turn(session_id="chat-9", user_message="compra un iphone 18 pro max")
        self.assertEqual(self.errands.listing(self.home), [], "nothing starts before the person chooses")
        self.assertIn("Lo que sé", note["context"])
        self.assertIn("purchase_options", note["context"])
        # The chat searches, reads pages and asks...
        for tool, args in (("browser_navigate", {"url": "https://www.apple.com/es/shop"}),
                           ("browser_exec", {"code": "print(page_info())"}), ("ask_person", {"questions": []})):
            self.assertIsNone(self.plugin._guard_chat_errand(tool, args, session_id="chat-9"))
        # ...but never fills a cart: that is the chosen option's errand.
        for tool, args in (("browser_click", {"text": "Añadir a la cesta"}),
                           ("browser_exec", {"code": "# Añadir al carrito\nclick('Add to bag')"})):
            self.assertEqual(self.plugin._guard_chat_errand(tool, args, session_id="chat-9")["action"], "block")
        # Inside an errand the chat's rules do not apply.
        entry = self.errand()
        self.assertIsNone(self.plugin._errand_turn(session_id=entry["session_id"], user_message="compra"))
        self.assertIsNone(self.plugin._guard_chat_errand("browser_click", {"text": "Añadir a la cesta"},
                                                         session_id=entry["session_id"]))
        # Something else is just a turn.
        self.assertIsNone(self.plugin._errand_turn(session_id="chat-9", user_message="dame los titulares de HN"))

    def test_a_purchase_starts_only_from_an_option_shown_in_that_chat(self):
        handler = self.tools()["errand_start"]["handler"]
        self.assertIn("purchase_options", self.call(handler, {"task": "Comprar un iPhone", "title": "iPhone"})["error"])
        first, second = self.shown()
        # Shown but not chosen: words alone still do not start it.
        self.assertFalse(self.call(handler, {"task": "La creatina de HSN", "title": "Creatina"})["ok"])
        self.assertFalse(self.call(handler, {"option_id": first}, session="chat-other")["ok"])
        self.assertFalse(self.call(handler, {"option_id": second})["ok"], "The model cannot choose a format")
        self.flow.choose(self.home, "chat-9", second)
        out = self.call(handler, {"option_id": second})
        self.assertTrue(out["ok"])
        entry = self.errands.get(self.home, out["errand_id"])
        self.assertEqual(entry["offer"]["url"], "https://www.prozis.com/creatina")
        self.assertEqual(entry["offer"]["price"], "19,99 €")
        self.assertEqual(entry["origin_session"], "chat-9")
        # The same option again is the same errand.
        self.assertEqual(self.call(handler, {"option_id": second})["errand_id"], out["errand_id"])

    def test_a_booking_is_not_a_purchase(self):
        handler = self.tools()["errand_start"]["handler"]
        out = self.call(handler, {"task": "Resérvame la ITV el jueves", "title": "Reservar la ITV"}, session="chat-2")
        self.assertTrue(out["ok"])
        self.assertIsNone(self.errands.get(self.home, out["errand_id"])["offer"])

    def test_a_tapped_option_starts_its_errand_before_the_model_runs(self):
        first, _second = self.shown()
        note = self.plugin._errand_turn(session_id="chat-9", user_message=f"[elección:{first}] Creatina Excell 500 g")
        started = self.errands.listing(self.home)
        self.assertEqual(len(started), 1)
        self.assertEqual(started[0]["offer"]["option_id"], first)
        self.assertIn(started[0]["id"], note["context"])
        self.assertIn(first, note["context"])
        # The model's errand_start that turn, however worded, is that errand.
        handler = self.tools()["errand_start"]["handler"]
        self.assertEqual(self.call(handler, {"task": "Comprar creatina", "title": "HSN"})["errand_id"], started[0]["id"])
        # An option from another chat is not this chat's to buy.
        other = self.plugin._errand_turn(session_id="chat-2", user_message=f"[elección:{first}] Creatina")
        self.assertIn("purchase_options", other["context"])
        self.assertEqual(len(self.errands.listing(self.home)), 1)

    def test_the_options_tool_is_the_chats_and_keeps_only_what_can_be_bought(self):
        handler = self.tools()["purchase_options"]["handler"]
        details = types.SimpleNamespace(load_details=lambda home: {"currency": "EUR"})
        options = {"options": [
            {"title": "A", "price": "10 €", "currency": "EUR", "url": "https://a.example/p", "in_stock": True,
             "channel": "browser", "image": "https://a.example/p.jpg"},
            {"title": "B", "price": "$12", "currency": "USD", "url": "https://b.example/p", "in_stock": True,
             "channel": "browser"},
        ]}
        with mock.patch.object(self.plugin, "_ask_person", return_value=details), \
                mock.patch.dict(sys.modules, {"hermes_constants": types.SimpleNamespace(get_hermes_home=lambda: self.home)}):
            out = self.call(handler, options)
            inside = self.call(handler, options, session="errand-1")
        self.assertFalse(out["ok"], "Unverified model prices must not become product cards")
        self.assertIn("formatos", out["error"])
        self.assertFalse(inside["ok"])

    def test_only_an_errands_browser_code_is_put_in_its_own_context(self):
        entry = self.errand()
        out = self.plugin._isolate_errand_browser("browser_exec", {"code": "# Abrir HSN\ngoto_url('x')"},
                                                  session_id=entry["session_id"])
        self.assertEqual(out["action"], "modify")
        self.assertTrue(out["args"]["code"].endswith("# Abrir HSN\ngoto_url('x')"))
        self.assertEqual(out["args"]["session"], entry["session_id"])
        preserved = self.plugin._isolate_errand_browser(
            "browser_exec", {"code": "# Abrir HSN", "timeout_s": 45, "session": "wrong"},
            session_id=entry["session_id"])
        self.assertEqual(preserved["args"]["timeout_s"], 45)
        self.assertEqual(preserved["args"]["session"], entry["session_id"])
        self.assertIsNone(self.plugin._isolate_errand_browser("browser_exec", {"code": "x"}, session_id="chat-1"))
        self.assertIsNone(self.plugin._isolate_errand_browser("web_search", {"query": "x"},
                                                              session_id=entry["session_id"]))
        # The step shown is the agent's comment, not Alice's note in front of it.
        self.plugin._errand_step("browser_exec", out["args"], entry["session_id"])
        self.assertEqual(self.errands.get(self.home, entry["id"])["steps"][-1]["text"], "Abrir HSN")

    def test_rephrased_tool_calls_reference_the_tapped_errand_even_after_it_stops(self):
        handler = self.tools()["errand_start"]["handler"]
        first_id, _ = self.shown()
        self.plugin._errand_turn(session_id="chat-9", user_message=f"[elección:{first_id}] Creatina")
        entry = self.errands.listing(self.home)[0]
        first = self.call(handler, {"task": "Comprar Creapure 300 g", "title": "Creatina"})
        self.errands.update(self.home, entry["id"], status="stuck", reason="Falta la dirección")
        second = self.call(handler, {"option_id": first_id})
        self.assertEqual(first["errand_id"], entry["id"])
        self.assertEqual(second["errand_id"], entry["id"])
        self.assertEqual(second["status"], "stuck")
        self.assertEqual(len(self.errands.listing(self.home)), 1)

    def test_a_second_distinct_choice_in_the_same_chat_gets_its_own_errand(self):
        first, second = self.shown()
        self.plugin._errand_turn(session_id="chat-9", user_message=f"[elección:{first}] A")
        one = self.plugin._ERRAND_TURN_IDS["chat-9"]
        self.plugin._errand_turn(session_id="chat-9", user_message=f"[elección:{second}] B")
        two = self.plugin._ERRAND_TURN_IDS["chat-9"]
        self.assertNotEqual(one, two)
        self.assertEqual(len(self.errands.listing(self.home)), 2)

    def test_a_routine_never_starts_an_errand(self):
        handler = self.tools()["errand_start"]["handler"]
        first, _ = self.shown()
        cron = self.call(handler, {"task": "Reservar la ITV", "title": "ITV"}, session="cron_abc_20260930_213015")
        self.assertFalse(cron["ok"])
        # A routine's output reviewed in a chat is not the person either, even with a choice token in it.
        review = "[Cronjob \"Cierre del día\" output — scheduled job, not the user.] Queda pendiente la creatina."
        self.assertIsNone(self.plugin._errand_turn(session_id="chat-9", user_message=review))
        self.assertFalse(self.call(handler, {"option_id": first})["ok"])
        self.assertIsNone(self.plugin._errand_turn(
            session_id="chat-9", user_message=f"[IMPORTANT: You are running as a scheduled cron job.] [elección:{first}]"))
        self.assertEqual(self.errands.listing(self.home), [])
        # The person's next turn in that chat can buy again.
        self.plugin._errand_turn(session_id="chat-9", user_message=f"[elección:{first}] Creatina")
        self.assertEqual(len(self.errands.listing(self.home)), 1)

    def test_during_a_purchase_no_invented_choices_and_no_country_questions(self):
        registered = {}
        ctx = types.SimpleNamespace(register_tool=lambda **kw: registered.__setitem__(kw["name"], kw))
        asker = types.SimpleNamespace(
            SCHEMA={"description": "ask"}, _normalized=lambda args: args.get("questions") or [],
            run_tool=lambda home, args, key: {"ok": True, "asked": [q["id"] for q in args["questions"]]})
        with mock.patch.object(self.plugin, "_ask_person", return_value=asker), \
                mock.patch.object(self.plugin, "_keep_ask_person_visible"):
            self.plugin._register_ask_tools(ctx)
        handler = registered["ask_person"]["handler"]
        self.plugin._errand_turn(session_id="chat-9", user_message="Compra la creatina creapure de prozis")
        guessed = {"questions": [{"id": "formato", "question": "¿Qué formato?", "choices": ["500 g", "1 kg"]}]}
        country = {"questions": [{"id": "c", "question": "País de entrega", "field": "country"}]}
        hermes = types.SimpleNamespace(get_hermes_home=lambda: self.home)
        with mock.patch.dict(sys.modules, {"hermes_constants": hermes}), \
                mock.patch.object(self.plugin, "_conversation_key", return_value="chat-9"):
            self.assertFalse(self.call(handler, guessed)["ok"])
            self.assertFalse(self.call(handler, country)["ok"])
            # Once it has looked at the shop, it may ask among what exists.
            self.plugin._guard_chat_errand("browser_exec", {"code": "print(page_info())"}, session_id="chat-9")
            self.assertTrue(self.call(handler, guessed)["ok"])
            self.assertFalse(self.call(handler, country)["ok"])
        # Outside a purchase nothing changes.
        with mock.patch.dict(sys.modules, {"hermes_constants": hermes}), \
                mock.patch.object(self.plugin, "_conversation_key", return_value="chat-2"):
            self.assertTrue(self.call(handler, guessed, session="chat-2")["ok"])

    def test_a_purchase_that_cannot_start_says_so(self):
        first, _ = self.shown()
        with mock.patch.object(self.plugin, "_start_purchase", side_effect=RuntimeError("gateway down")):
            note = self.plugin._errand_turn(session_id="chat-9", user_message=f"[elección:{first}] Creatina")
        self.assertIn("No he podido iniciar la compra", note["context"])
        self.assertIn("sin decir que está en marcha", note["context"])
        self.assertEqual(self.errands.listing(self.home), [])

    def test_the_text_only_repeat_guard_does_not_pause_an_errand(self):
        guard = mock.Mock()
        approval = types.SimpleNamespace(get_current_session_key=lambda **_: "run-1")
        with mock.patch.dict(sys.modules, {"tools.approval_context": approval}), \
                mock.patch.object(self.plugin, "_task_finish", return_value=types.SimpleNamespace(guard_repeat=guard)):
            with mock.patch.object(self.plugin, "_session_id", return_value="errand-123"):
                self.plugin._repeat_guard(user_message="continue", assistant_response="same")
                guard.assert_not_called()
            with mock.patch.object(self.plugin, "_session_id", return_value="chat-1"):
                self.plugin._repeat_guard(user_message="continue", assistant_response="same")
                guard.assert_called_once_with("continue", "same", "run-1")

if __name__ == "__main__":
    unittest.main()
