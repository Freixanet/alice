"""Errands run apart from the chat, and nothing is paid without the person's approved checkout.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import concurrent.futures
import json
import time
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
PATH = Path(__file__).resolve().parents[1] / "errands.py"
spec = importlib.util.spec_from_file_location("alice_errands_test", PATH)
errands = importlib.util.module_from_spec(spec)
spec.loader.exec_module(errands)

NOW = 1_800_000_000.0
GATEWAYS = {"sis.redsys.es"}
CHECKOUT = {
    "merchant": "HSN", "site": "https://www.hsnstore.com/checkout/index/index/step/payment/",
    "items": [{"name": "Creatina Excell 500 g (Creapure®)", "variant": "Sin sabor", "qty": 1, "price": "27,98 €",
               "image": "https://www.hsnstore.com/media/creatina.jpg"}],
    "delivery": "Envío gratis · llega el viernes", "email": "persona@example.com",
    "card_label": "Visa ···4242", "total": "27,98 €", "currency": "eur",
}


def offline(url, limit, accept):
    raise OSError("tests do not go online")


class Base(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        # Pictures are checked from the Mac; tests never go online.
        patch = mock.patch.object(errands, "_fetch", offline)
        patch.start()
        self.addCleanup(patch.stop)

    def errand(self, **kwargs):
        return errands.create(self.home, "Compra la creatina Creapure de HSN", title="Comprar Creapure en HSN",
                              site="hsnstore.com", now=NOW, **kwargs)


class StoreTests(Base):
    def test_an_errand_has_its_own_session_never_the_chats(self):
        entry = self.errand(origin_session="20260922_155237_281345")
        self.assertEqual(entry["status"], "working")
        self.assertEqual(entry["session_id"], "errand-" + entry["id"])
        self.assertEqual(errands.of_session(self.home, entry["session_id"])["id"], entry["id"])
        # The chat it was asked from is not the errand.
        self.assertIsNone(errands.of_session(self.home, "20260922_155237_281345"))

    def test_an_errand_needs_a_task(self):
        with self.assertRaises(ValueError):
            errands.create(self.home, "   ")

    def test_steps_keep_the_latest_and_skip_repeats(self):
        entry = self.errand()
        errands.add_step(self.home, entry["id"], "Abrir HSN", "https://www.hsnstore.com/")
        errands.add_step(self.home, entry["id"], "Abrir HSN", "https://www.hsnstore.com/")
        for n in range(errands.MAX_STEPS + 5):
            errands.add_step(self.home, entry["id"], f"Paso {n}")
        steps = errands.get(self.home, entry["id"])["steps"]
        self.assertEqual(len(steps), errands.MAX_STEPS)
        self.assertEqual(steps[-1]["text"], f"Paso {errands.MAX_STEPS + 4}")

    def test_what_alice_sees_leaves_out_the_session_wiring(self):
        entry = errands.update(self.home, self.errand()["id"], run_id="run_1",
                               approval={"run_id": "run_1", "request_id": "r1", "title": "¿Entrar?"})
        shown = errands.public(entry)
        self.assertNotIn("run_id", shown)
        self.assertIn("origin_session", shown)
        self.assertNotIn("run_id", shown["approval"])


class CheckoutTests(Base):
    def test_checkout_and_approval_keep_cents_and_currency(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry['id'], {**CHECKOUT, 'currency': ''}, now=NOW)
        checkout = errands.get(self.home, entry['id'])['checkout']
        self.assertEqual((checkout['total_cents'], checkout['currency']), (2798, 'EUR'))
        decided = errands.decide_checkout(self.home, entry['id'], True, now=NOW + 1)
        self.assertEqual((decided['checkout']['approved_cents'], decided['checkout']['approved_currency']), (2798, 'EUR'))

    def test_invalid_checkout_total_never_waits_for_approval(self):
        for total in ('consultar', '-27,98 €', '$27.98'):
            with self.subTest(total=total):
                entry = self.errand()
                result = errands.request_checkout(self.home, entry['id'], {**CHECKOUT, 'total': total}, now=NOW)
                self.assertFalse(result['ok'])
                self.assertEqual(errands.get(self.home, entry['id'])['status'], 'working')

    def test_a_checkout_needs_the_shop_the_items_and_the_total(self):
        entry = self.errand()
        out = errands.request_checkout(self.home, entry["id"], {"merchant": "HSN", "items": [], "total": ""})
        self.assertFalse(out["ok"])
        self.assertEqual(errands.get(self.home, entry["id"])["status"], "working")

    def test_a_checkout_waits_for_the_person(self):
        entry = self.errand()
        out = errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW)
        self.assertTrue(out["ok"])
        saved = errands.get(self.home, entry["id"])
        self.assertEqual(saved["status"], "needs_approval")
        checkout = saved["checkout"]
        self.assertEqual((checkout["status"], checkout["site"], checkout["total"]), ("pending", "hsnstore.com", "27,98 €"))
        self.assertEqual(checkout["currency"], "EUR")
        self.assertEqual(checkout["items"][0]["qty"], 1)

    def test_only_https_images_are_kept(self):
        entry = self.errand()
        items = [{"name": "X", "image": "javascript:alert(1)"}, {"name": "Y", "image": "http://x/y.jpg"}]
        errands.request_checkout(self.home, entry["id"], {**CHECKOUT, "items": items})
        self.assertEqual([i["image"] for i in errands.get(self.home, entry["id"])["checkout"]["items"]], ["", ""])

    def test_allow_approves_that_shop_for_ten_minutes(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW)
        decided = errands.decide_checkout(self.home, entry["id"], True, now=NOW + 5)
        self.assertEqual(decided["status"], "working")
        self.assertIsNotNone(errands.approved_checkout(decided, "https://www.hsnstore.com/x", now=NOW + 60))
        self.assertIsNone(errands.approved_checkout(decided, "https://otra-tienda.es", now=NOW + 60))
        self.assertIsNone(errands.approved_checkout(decided, now=NOW + 5 + errands.APPROVAL_TTL + 1))
        # A decision is taken once.
        self.assertIsNone(errands.decide_checkout(self.home, entry["id"], False, now=NOW + 10))

    def test_without_a_saved_card_the_person_is_asked_for_one_before_the_total(self):
        entry = self.errand()
        out = errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW, saved_cards=lambda: [])
        saved = errands.get(self.home, entry["id"])
        self.assertEqual((out["status"], saved["status"], saved["card_origin"]),
                         ("needs_card", "needs_card", "https://hsnstore.com"))
        self.assertIsNone(saved["checkout"], "no total is shown before there is a way to pay")

    def test_the_card_is_the_one_read_else_the_only_one_else_the_last_used(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], {**CHECKOUT, "card_label": ""}, now=NOW,
                                 saved_cards=lambda: [{"label": "Visa ···4242"}])
        self.assertEqual(errands.get(self.home, entry["id"])["checkout"]["card_label"], "Visa ···4242")
        paid = self.errand()
        errands.update(self.home, paid["id"], receipt={"outcome": "paid", "site": "hsnstore.com",
                                                       "card_label": "Mastercard ···5100"})
        other = self.errand()
        errands.request_checkout(self.home, other["id"], {**CHECKOUT, "card_label": ""}, now=NOW,
                                 saved_cards=lambda: [{"label": "Visa ···4242"}, {"label": "Mastercard ···5100"}])
        self.assertEqual(errands.get(self.home, other["id"])["checkout"]["card_label"], "Mastercard ···5100")

    def test_the_yes_is_to_that_total(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW)
        decided = errands.decide_checkout(self.home, entry["id"], True, now=NOW + 5, card_label="Visa ···4242")
        self.assertEqual(decided["checkout"]["approved_total"], "27,98 €")
        message = errands.approved_message(decided["checkout"])
        self.assertTrue(message.startswith(errands.APPROVED_PREFIX))
        self.assertIn("exactamente 27,98 €", message)
        self.assertIn("NO pagues", message)
        # Paid another amount: the receipt says so.
        errands.record_receipt(self.home, entry["session_id"], {"outcome": "paid", "order": "1", "total": "29,98 €"})
        self.assertEqual(errands.get(self.home, entry["id"])["receipt"]["approved_total"], "27,98 €")

    def test_the_same_amount_written_differently_is_not_a_difference(self):
        self.assertTrue(errands.same_amount("27,98 €", "EUR 27.98"))
        self.assertFalse(errands.same_amount("27,98 €", "29,98 €"))
        self.assertFalse(errands.same_amount("", ""))

    def test_deny_ends_the_errand(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW)
        decided = errands.decide_checkout(self.home, entry["id"], False, now=NOW + 5)
        self.assertEqual(decided["status"], "denied")
        self.assertEqual(decided["checkout"]["status"], "denied")
        self.assertIsNone(errands.approved_checkout(decided, now=NOW + 6))

    def test_the_receipt_takes_what_the_checkout_showed(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW)
        errands.record_receipt(self.home, entry["session_id"], {"site": "hsnstore.com", "outcome": "paid",
                                                                "order": "100123456"}, now=NOW + 90)
        receipt = errands.get(self.home, entry["id"])["receipt"]
        self.assertEqual((receipt["order"], receipt["total"], receipt["card_label"]), ("100123456", "27,98 €", "Visa ···4242"))
        self.assertEqual(receipt["items"][0]["name"], "Creatina Excell 500 g (Creapure®)")
        # Outside an errand nothing is written.
        errands.record_receipt(self.home, "20260922_155237_281345", {"outcome": "paid"})


class GateTests(Base):
    def approved(self, site=CHECKOUT["site"], at=NOW):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], {**CHECKOUT, "site": site}, now=at)
        errands.decide_checkout(self.home, entry["id"], True, now=at)
        return entry

    def test_a_chat_can_never_pay(self):
        verdict = errands.pay_gate(self.home, "20260922_155237_281345", card_fill_site="https://www.hsnstore.com")
        self.assertEqual(verdict["action"], "block")
        self.assertIn("errand_start", verdict["message"])

    def test_an_errand_without_an_approved_checkout_cannot_fill_a_card(self):
        entry = self.errand()
        verdict = errands.pay_gate(self.home, entry["session_id"], card_fill_site="https://www.hsnstore.com")
        self.assertEqual(verdict["action"], "block")
        self.assertIn("checkout_request", verdict["message"])
        errands.request_checkout(self.home, entry["id"], CHECKOUT)
        self.assertEqual(errands.pay_gate(self.home, entry["session_id"], card_fill_site="https://www.hsnstore.com")["action"], "block")

    def test_the_approved_shop_and_its_bank_page_can_be_paid(self):
        entry = self.approved(at=NOW)
        session = entry["session_id"]
        self.assertIsNone(errands.pay_gate(self.home, session, card_fill_site="https://www.hsnstore.com", now=NOW + 30))
        self.assertIsNone(errands.pay_gate(self.home, session, card_fill_site="https://sis.redsys.es",
                                           gateways=GATEWAYS, now=NOW + 30))
        self.assertIsNone(errands.pay_gate(self.home, session, card_fill_site="https://pay.example",
                                           merchant_site="hsnstore.com", now=NOW + 30))
        # Another shop, or too late, is not covered.
        self.assertIsNotNone(errands.pay_gate(self.home, session, card_fill_site="https://amazon.es", now=NOW + 30))
        self.assertIsNotNone(errands.pay_gate(self.home, session, card_fill_site="https://www.hsnstore.com",
                                              now=NOW + errands.APPROVAL_TTL + 5))

    def test_choosing_how_to_pay_on_the_payment_page_is_not_paying(self):
        page = "https://www.hsnstore.com/checkout/index/index/step/payment/"
        for args in ({"text": "Tarjeta de crédito"}, {"code": "click('Acepto las condiciones')"},
                     {"code": "click('PayPal')"}, {"code": "# Elegir método\nclick('Forma de pago: tarjeta')"}):
            self.assertFalse(errands.is_pay_action("browser_click", args, page), args)
        for args in ({"text": "Pagar"}, {"code": "click('Realizar pedido')"}, {"code": "click_at_xy(400,508)"},
                     {"code": "click('Continuar')"}):
            self.assertTrue(errands.is_pay_action("browser_click", args, page), args)

    def test_a_click_that_pays_is_refused_until_approved(self):
        entry = self.errand()
        session = entry["session_id"]
        named = {"code": "# Pay\nclick_text('Realizar pedido')"}
        self.assertEqual(errands.pay_gate(self.home, session, tool_name="browser_exec", args=named)["action"], "block")
        # A click by coordinates on the payment step.
        pay_page = "https://www.hsnstore.com/checkout/index/index/step/payment/"
        by_xy = {"code": "click_at_xy(400,508)"}
        self.assertIsNotNone(errands.pay_gate(self.home, session, tool_name="browser_exec", args=by_xy,
                                              active_url=pay_page))
        # The same click on a product page, or reading the payment page, is fine.
        self.assertIsNone(errands.pay_gate(self.home, session, tool_name="browser_exec", args=by_xy,
                                           active_url="https://www.hsnstore.com/creatina"))
        self.assertIsNone(errands.pay_gate(self.home, session, tool_name="browser_exec",
                                           args={"code": "print(page_info())"}, active_url=pay_page))
        self.assertIsNone(errands.pay_gate(self.home, session, tool_name="web_search", args=named))

    def test_reading_controls_that_mention_payment_does_not_need_payment_approval(self):
        entry = self.errand()
        code = "# Revisar la cesta antes de continuar\nprint(js('Array.from(document.querySelectorAll(\"button,a\")).map(e=>e.innerText).filter(t=>/cesta|carrito|añadir|checkout|pagar/i.test(t))'))\ncapture_screenshot()"
        for page in ("https://www.prozis.com/product", "https://www.prozis.com/checkout/payment"):
            self.assertIsNone(errands.pay_gate(self.home, entry["session_id"], tool_name="browser_exec",
                                              args={"code": code}, active_url=page))
        for code in ("click_text('Pagar')", "js(\"document.querySelector('button').click()\")"):
            self.assertIsNotNone(errands.pay_gate(self.home, entry["session_id"], tool_name="browser_exec",
                                                 args={"code": code}, active_url="https://www.prozis.com/checkout/payment"))

    def test_an_approved_checkout_lets_the_pay_click_through(self):
        entry = self.approved(at=NOW)
        self.assertIsNone(errands.pay_gate(self.home, entry["session_id"], tool_name="browser_exec",
                                           args={"code": "click_text('Pagar')"}, now=NOW + 20))

    def test_a_saved_login_is_used_without_asking_unless_asked_to_ask(self):
        self.assertIsNone(errands.login_gate(self.home, self.errand()["session_id"]))
        self.assertIsNone(errands.login_gate(self.home, "chat-session"))
        careful = self.errand(ask_before_login=True)
        verdict = errands.login_gate(self.home, careful["session_id"])
        self.assertEqual(verdict["action"], "approve")
        self.assertTrue(verdict["rule_key"].startswith("alice-errand-login:"))

    def test_hermes_payment_confirmation_is_recognised(self):
        approval = {"command": "Fill payment card 'Visa ···4242' on https://www.hsnstore.com"}
        self.assertTrue(errands.is_payment_consent(approval))
        self.assertEqual(errands.consent_site(approval), "https://www.hsnstore.com")
        self.assertFalse(errands.is_payment_consent({"command": "rm -rf build"}))


class FakeGateway:
    """Scripted runs: each run is a list of status dicts returned by successive polls."""

    def __init__(self, runs, on_start=None, fail=False):
        self.runs = list(runs)
        self.on_start = on_start or (lambda n: None)
        self.fail = fail
        self.started, self.approvals, self.stopped = [], [], []
        self.models = []
        self.current = []

    def start(self, session_id, text, *, model, provider):
        if self.fail:
            raise OSError("connection refused")
        self.started.append((session_id, text))
        self.models.append({"model": model, "provider": provider})
        self.on_start(len(self.started))
        self.current = list(self.runs.pop(0)) if self.runs else [{"status": "completed", "output": ""}]
        return f"run_{len(self.started)}"

    def status(self, run_id):
        return self.current.pop(0) if len(self.current) > 1 else self.current[0]

    def approve(self, run_id, choice, request_id=""):
        self.approvals.append((run_id, choice, request_id))
        self.current = [s for s in self.current if s.get("status") != "waiting_for_approval"] or [{"status": "running"}]
        return True

    def stop(self, run_id):
        self.stopped.append(run_id)


def done(output="Pedido 100123456 realizado."):
    return [{"status": "completed", "output": output}]


class EngineTests(Base):
    def engine(self, gateway, verdicts):
        entry = self.errand()
        seen = []

        def judge(session_id, reply):
            seen.append((session_id, reply))
            return verdicts.pop(0) if verdicts else {"status": "done"}

        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=judge, sleep=lambda s: None)
        return entry, engine, seen

    def test_the_errand_runs_in_its_own_session_until_the_judge_says_done(self):
        gateway = FakeGateway([done("Buscando la creatina"), done("Checkout abierto")])
        entry, engine, seen = self.engine(gateway, [
            {"status": "active", "should_continue": True, "continuation_prompt": "[Continuing toward your standing goal] sigue"},
            {"status": "done", "should_continue": False}])
        self.assertEqual(engine.run(), "done")
        self.assertEqual([s for s, _ in gateway.started], [entry["session_id"]] * 2)
        self.assertIn("Compra la creatina Creapure de HSN", gateway.started[0][1])
        self.assertIn("checkout_request", gateway.started[0][1])
        self.assertTrue(gateway.started[1][1].startswith("[Continuing toward your standing goal]"))
        self.assertEqual([s for s, _ in seen], [entry["session_id"]] * 2)
        saved = errands.get(self.home, entry["id"])
        self.assertEqual((saved["status"], saved["runs"], saved["summary"]), ("done", 2, "Checkout abierto"))
        self.assertEqual(gateway.models, [{"model": "gpt-6-luna", "provider": "openai-codex"}] * 2)

    def test_a_resumed_errand_keeps_its_saved_model_when_the_default_changes(self):
        entry = self.errand()
        config = self.home / ".alice" / "errand-model.json"
        config.write_text(json.dumps({"model": "different-model", "provider": "openai-codex"}))
        gateway = FakeGateway([done()])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway,
                                judge=lambda *_: {"status": "done"}, sleep=lambda _: None)
        self.assertEqual(engine.run("La persona respondió"), "done")
        self.assertEqual(gateway.models, [{"model": "gpt-6-luna", "provider": "openai-codex"}])
        self.assertEqual(self.errand()["model"], "different-model")

    def test_an_older_errand_saves_the_fixed_route_before_resuming(self):
        entry = self.errand()
        records = errands._read(errands._path(self.home))
        records[0].pop("model")
        records[0].pop("provider")
        errands._write(errands._path(self.home), records)
        gateway = FakeGateway([done()])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway,
                                judge=lambda *_: {"status": "done"}, sleep=lambda _: None)
        saved = errands.get(self.home, entry["id"])
        self.assertEqual((saved["model"], saved["provider"]), ("gpt-6-luna", "openai-codex"))
        self.assertEqual(engine.run(), "done")
        self.assertEqual(gateway.models, [{"model": "gpt-6-luna", "provider": "openai-codex"}])

    def test_a_checkout_request_parks_the_errand_without_asking_the_judge(self):
        holder = {}

        def on_start(n):
            errands.request_checkout(self.home, holder["id"], CHECKOUT)

        gateway = FakeGateway([done("Checkout esperando aprobación")], on_start=on_start)
        entry, engine, seen = self.engine(gateway, [])
        holder["id"] = entry["id"]
        self.assertEqual(engine.run(), "needs_approval")
        self.assertEqual(seen, [])

    def test_hermes_card_confirmation_is_answered_only_for_an_approved_checkout(self):
        consent = {"status": "waiting_for_approval",
                   "approval": {"command": "Fill payment card 'Visa ···4242' on https://www.hsnstore.com",
                                "request_id": "req-1"}}
        gateway = FakeGateway([[{"status": "running"}, consent, {"status": "completed", "output": "No pagado"}]])
        entry, engine, _ = self.engine(gateway, [{"status": "done"}])
        engine.run()
        self.assertEqual(gateway.approvals, [("run_1", "deny", "req-1")])

        gateway = FakeGateway([[{"status": "running"}, consent, {"status": "completed", "output": "Pagado"}]])
        entry, engine, _ = self.engine(gateway, [{"status": "done"}])
        errands.request_checkout(self.home, entry["id"], CHECKOUT)
        errands.decide_checkout(self.home, entry["id"], True)
        engine.run()
        self.assertEqual(gateway.approvals, [("run_1", "once", "req-1")])

    def test_another_confirmation_goes_to_the_person(self):
        ask = {"status": "waiting_for_approval",
               "approval": {"command": "Iniciar sesión en hsnstore.com", "request_id": "req-9",
                            "description": "El recado quiere iniciar sesión", "choices": ["once", "session", "deny"]}}
        gateway = FakeGateway([[ask]])
        entry, engine, _ = self.engine(gateway, [])

        def answer_later(seconds):
            pending = errands.get(self.home, entry["id"])
            if pending["status"] == "needs_approval":
                self.assertEqual(pending["approval"]["choices"], ["once", "deny"])
                gateway.current = [{"status": "completed", "output": "Hecho"}]

        engine.sleep = answer_later
        engine.run()
        self.assertEqual(gateway.approvals, [])

    def test_a_paid_receipt_finishes_the_errand(self):
        holder = {}

        def on_start(n):
            errands.record_receipt(self.home, "errand-" + holder["id"], {"site": "hsnstore.com", "outcome": "paid",
                                                                         "order": "100123456"})

        gateway = FakeGateway([done()], on_start=on_start)
        entry, engine, seen = self.engine(gateway, [])
        holder["id"] = entry["id"]
        self.assertEqual(engine.run(), "done")
        self.assertEqual(seen, [])

    def test_repeating_the_same_reply_leaves_it_stuck(self):
        same = "No encuentro la creatina en la tienda, sigo buscando variantes del nombre oficial"
        keep = {"status": "active", "should_continue": True, "continuation_prompt": "[Continuing toward your standing goal]"}
        gateway = FakeGateway([done(same), done(same), done(same)])
        entry, engine, _ = self.engine(gateway, [dict(keep), dict(keep), dict(keep)])
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(len(gateway.started), 3)
        self.assertIn("Inspecciona el estado actual", gateway.started[2][1])
        self.assertIn("recuperación", errands.get(self.home, entry["id"])["reason"])

    def test_similar_summaries_do_not_stop_new_browser_steps(self):
        same = "La compra sigue en marcha mientras completo los datos en la página de la tienda"
        holder = {}

        def on_start(n):
            errands.add_step(self.home, holder["id"], f"Paso {n}", f"https://shop.example/step/{n}")

        gateway = FakeGateway([done(same), done(same), done("Pedido confirmado")], on_start=on_start)
        entry, engine, _ = self.engine(gateway, [
            {"should_continue": True}, {"should_continue": True}, {"status": "done"}])
        holder["id"] = entry["id"]
        self.assertEqual(engine.run(), "done")
        self.assertEqual(len(gateway.started), 3)

    def test_a_loop_gets_one_recovery_and_can_reach_a_real_wait(self):
        same = "No puedo continuar con el checkout porque la tienda sigue pidiendo los mismos datos"
        holder = {}

        def on_start(n):
            if n == 3:
                errands.ask(self.home, holder["id"], "Dirección", [{"id": "address", "question": "¿Dirección?"}])

        gateway = FakeGateway([done(same), done(same), done("Espera tu respuesta")], on_start=on_start)
        entry, engine, _ = self.engine(gateway, [{"should_continue": True}])
        holder["id"] = entry["id"]
        self.assertEqual(engine.run(), "needs_input")
        self.assertEqual(len(gateway.started), 3)

    def test_a_judge_that_gives_up_leaves_it_stuck_with_the_reason(self):
        gateway = FakeGateway([done("Sin stock")])
        entry, engine, _ = self.engine(gateway, [{"status": "paused", "should_continue": False,
                                                  "reason": "No hay stock de 500 g"}])
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(errands.get(self.home, entry["id"])["reason"], "No hay stock de 500 g")

    def test_no_gateway_leaves_it_stuck(self):
        entry, engine, _ = self.engine(FakeGateway([], fail=True), [])
        self.assertEqual(engine.run(), "stuck")
        self.assertIn("Hermes", errands.get(self.home, entry["id"])["reason"])

    def test_stopping_cancels_the_run(self):
        gateway = FakeGateway([[{"status": "running"}]])
        entry, engine, _ = self.engine(gateway, [])

        def stop_now(seconds):
            errands.update(self.home, entry["id"], status="stopped")

        engine.sleep = stop_now
        self.assertEqual(engine.run(), "stopped")
        self.assertEqual(gateway.stopped, ["run_1"])

    def test_the_run_budget_is_a_backstop(self):
        keep = {"status": "active", "should_continue": True, "continuation_prompt": "sigue"}
        runs = [done(" ".join(f"w{n}x{k}" for k in range(8))) for n in range(errands.MAX_RUNS + 2)]
        gateway = FakeGateway(runs)
        entry, engine, _ = self.engine(gateway, [dict(keep) for _ in range(errands.MAX_RUNS + 2)])
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(len(gateway.started), errands.MAX_RUNS)



class AuditFixTests(Base):
    """What the iPhone purchase of 29-09 got wrong: three copies of one errand, a stalled run."""

    def test_an_errand_never_starts_another_from_inside(self):
        entry = self.errand()
        out = errands.start(self.home, {"task": "Compra un iPhone", "title": "iPhone"},
                            origin_session=entry["session_id"])
        self.assertFalse(out["ok"])
        self.assertEqual(len(errands.listing(self.home)), 1)

    def test_the_same_chat_asking_again_gets_the_errand_under_way(self):
        first = errands.create(self.home, "Compra un iPhone", title="iPhone", origin_session="chat-1", now=NOW)
        out = errands.start(self.home, {"task": "Compra un iPhone", "title": "iPhone"},
                            origin_session="chat-1", now=NOW + 60)
        self.assertEqual(out["errand_id"], first["id"])
        self.assertEqual(len(errands.listing(self.home)), 1)

    def test_an_active_request_is_reused_after_ten_minutes(self):
        first = errands.create(self.home, "Compra un iPhone", origin_session="chat-1", now=NOW)
        out = errands.start(self.home, {"task": "  COMPRA un   iPhone "}, origin_session="chat-1", now=NOW + 900)
        self.assertEqual(out["errand_id"], first["id"])
        self.assertEqual(len(errands.listing(self.home)), 1)

    def test_a_different_request_or_profile_does_not_reuse_the_first_purchase(self):
        first = errands.create(self.home, "Compra un iPhone", origin_session="chat-1", profile="alice", now=NOW)
        with mock.patch.object(errands, "open_goal"), mock.patch.object(errands, "launch"):
            different = errands.start(self.home, {"task": "Compra la creatina"},
                                      origin_session="chat-1", profile="alice", now=NOW + 1)
            other_profile = errands.start(self.home, {"task": "Compra un iPhone"},
                                          origin_session="chat-1", profile="other", now=NOW + 2)
        self.assertEqual(len({first["id"], different["errand_id"], other_profile["errand_id"]}), 3)

    def test_simultaneous_starts_create_and_launch_one_errand(self):
        barrier = threading.Barrier(12)

        def start_once(_):
            barrier.wait(timeout=5)
            return errands.start(self.home, {"task": "Compra la creatina de Prozis"},
                                 origin_session="chat-1", profile="alice", now=NOW)["errand_id"]

        with mock.patch.object(errands, "open_goal") as goal, mock.patch.object(errands, "launch") as launch:
            with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
                ids = list(pool.map(start_once, range(12)))
        self.assertEqual(len(set(ids)), 1)
        self.assertEqual(len(errands.listing(self.home)), 1)
        goal.assert_called_once()
        launch.assert_called_once()

    def test_a_finished_request_can_be_started_again(self):
        first = errands.create(self.home, "Compra un iPhone", origin_session="chat-1", now=NOW)
        errands.update(self.home, first["id"], status="done")
        with mock.patch.object(errands, "open_goal"), mock.patch.object(errands, "launch"):
            out = errands.start(self.home, {"task": "Compra un iPhone"}, origin_session="chat-1", now=NOW + 1)
        self.assertNotEqual(out["errand_id"], first["id"])

    def test_only_a_real_domain_is_a_site(self):
        self.assertEqual(errands.shop("apple store españa (apple.com"), "")
        self.assertEqual(errands.shop("https://www.apple.com/es/shop"), "apple.com")
        self.assertEqual(errands.create(self.home, "x", site="apple store españa")["site"], "")

    def test_a_stalled_run_is_stopped_and_retried_once_then_stuck(self):
        clock = {"t": 0.0}
        frozen = {"status": "running", "updated_at": 1.0, "last_event": "tool.completed"}
        gateway = FakeGateway([[frozen], [frozen]])
        entry = self.errand()
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: clock.__setitem__("t", clock["t"] + 60))
        real_time = errands.time.time
        errands.time.time = lambda: clock["t"]
        try:
            self.assertEqual(engine.run(), "stuck")
        finally:
            errands.time.time = real_time
        self.assertEqual(gateway.stopped, ["run_1", "run_2"])
        self.assertIn("colgado", gateway.started[1][1])
        self.assertIn("dejó de responder", errands.get(self.home, entry["id"])["reason"])

    def test_the_card_rules_travel_with_the_errand(self):
        original = errands.card_rules
        errands.card_rules = lambda profile: f"## Pagar con tarjeta ({profile})"
        try:
            self.assertIn("## Pagar con tarjeta (default)", errands.brief({"request": "x", "profile": "default"}))
        finally:
            errands.card_rules = original

    def test_the_brief_never_starts_another_errand(self):
        self.assertIn("nunca llames a `errand_start`", errands.brief({"request": "x"}))

    def test_a_chosen_option_is_bought_as_chosen_or_the_errand_stops_and_says_why(self):
        offer = {"option_id": "a1b2c3d4-2", "title": "Creatina Excell 500 g", "merchant": "HSN",
                 "variant": "Sin sabor", "qty": 1, "price": "27,98 €", "currency": "EUR",
                 "url": "https://www.hsnstore.com/creatina", "checkout_url": "", "channel": "browser"}
        entry = errands.create(self.home, "Comprar Creatina", title="Comprar Creatina en HSN", now=NOW, offer=offer)
        brief = errands.brief(entry)
        for part in ("https://www.hsnstore.com/creatina", "Sin sabor", "27,98 €", "BLOQUEADO:", "nada más"):
            self.assertIn(part, brief)
        gateway = FakeGateway([done("BLOQUEADO: la variante sin sabor ya no está disponible.")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway,
                                judge=lambda s, r: self.fail("the judge is not asked"), sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(errands.get(self.home, entry["id"])["reason"],
                         "la variante sin sabor ya no está disponible.")

    def test_a_new_price_is_the_persons_to_accept_and_the_errand_goes_on(self):
        offer = {"option_id": "a1b2c3d4-1", "title": "Creatina 300 g", "merchant": "Prozis", "variant": "Neutro",
                 "qty": 1, "price": "24,49 €", "currency": "EUR", "url": "https://www.prozis.com/c", "channel": "browser"}
        entry = errands.create(self.home, "Comprar Creatina", now=NOW, offer=offer)
        gateway = FakeGateway([done("BLOQUEADO: precio 34,99 € — en la cesta no se aplica el 30 % de la ficha.")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        saved = errands.get(self.home, entry["id"])
        self.assertEqual(saved["blocked"], {"kind": "price", "price": "34,99 €"})
        with mock.patch.object(errands, "launch") as launched, mock.patch.object(errands, "_goal_manager"):
            went = errands.go_on(self.home, entry["id"], accept_price=True)
        self.assertEqual((went["status"], went["offer"]["price"], went["blocked"]), ("working", "34,99 €", None))
        self.assertIn("34,99 €", launched.call_args[0][2])
        self.assertIn("checkout_request", launched.call_args[0][2])
        # Only a stopped errand goes on, and a retry needs no price.
        self.assertIsNone(errands.go_on(self.home, entry["id"]))

    def test_same_price_and_crossed_out_price_are_not_a_price_change(self):
        offer = {"price": "24,49 €", "currency": "EUR", "url": "https://www.prozis.com/fixture", "title": "Creapure"}
        for said in ("precio 24,49 € en la ficha frente a 34,99 € tachados; no puedo confirmar el total del carrito.",
                     "la tienda muestra €24,49 en la ficha, pero no pude avanzar al carrito"):
            self.assertEqual(errands.blocked_by(said, offer), {"kind": "other"})
        self.assertEqual(errands.blocked_by("precio 34,99 € en la cesta", offer), {"kind": "price", "price": "34,99 €"})
        self.assertEqual(errands.blocked_by("el navegador no está disponible", offer), {"kind": "other"})
        entry = errands.create(self.home, "Comprar", offer=offer)
        gateway = FakeGateway([done("BLOQUEADO: precio 24,49 € en la ficha frente a 34,99 € tachados"),
                               done("BLOQUEADO: no se pudo confirmar la cesta")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, sleep=lambda _: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(len(gateway.started), 2)
        self.assertEqual(errands.get(self.home, entry["id"])["blocked"], {"kind": "other"})
        self.assertIn("precio tachado", gateway.started[1][1])

    def test_the_basket_price_is_remembered_for_that_page(self):
        offer = {"option_id": "a1b2c3d4-1", "url": "https://www.prozis.com/c?x=1", "price": "24,49 €"}
        entry = errands.create(self.home, "Comprar", now=NOW, offer=offer)
        errands.update(self.home, entry["id"], now=NOW, status="stuck", blocked={"kind": "price", "price": "34,99 €"})
        self.assertEqual(errands.basket_prices(self.home, now=NOW + 60), {"https://www.prozis.com/c": "34,99 €"})
        self.assertEqual(errands.basket_prices(self.home, now=NOW + 8 * 24 * 3600), {})

    def test_what_the_agent_can_fix_is_not_the_persons_to_hear(self):
        offer = {"option_id": "a1b2c3d4-2", "title": "Creatina 80 cápsulas", "price": "20,99 €",
                 "url": "https://www.prozis.com/c", "channel": "browser"}
        entry = errands.create(self.home, "Comprar Creatina", now=NOW, offer=offer)
        gateway = FakeGateway([
            done("BLOQUEADO: el checkout contiene Creatina 300 g, no las 80 cápsulas aceptadas."),
            done("BLOQUEADO: el checkout sigue con la de 300 g."),
        ])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(len(gateway.started), 2, "one go at fixing it before the person hears anything")
        self.assertIn("quítalos", gateway.started[1][1])
        self.assertIn("quítalos", errands.brief(entry))
        # The option gone, or another price, reaches the person at once.
        self.assertEqual(errands.blocked_by("la variante ya no está disponible"), {"kind": "gone"})

    def test_a_datum_the_shop_demands_is_asked_and_kept_not_a_stop(self):
        self.assertEqual(errands.blocked_by("Prozis exige una fecha de nacimiento para crear la cuenta y no permite continuar sin ella.")["kind"], "datum")
        self.assertEqual(errands.missing_datum("La tienda requiere el DNI para facturar")["field"], "id")
        self.assertIsNone(errands.missing_datum("La cesta tiene otro producto"))
        offer = {"option_id": "a1b2c3d4-1", "title": "Creatina", "price": "24,49 €", "currency": "EUR", "url": "https://www.prozis.com/c"}
        entry = errands.create(self.home, "Comprar Creatina", now=NOW, offer=offer)
        gateway = FakeGateway([done("BLOQUEADO: Prozis exige una fecha de nacimiento para crear la cuenta.")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"}, sleep=lambda s: None)
        self.assertEqual(engine.run(), "needs_input")
        saved = errands.get(self.home, entry["id"])
        self.assertEqual(saved["status"], "needs_input")
        self.assertEqual([q["id"] for q in saved["questions"]["items"]], ["birthdate"])
        self.assertTrue(saved["questions"]["fields"])
        self.assertIsNone(saved["blocked"])

    def test_an_errand_already_stopped_on_a_datum_becomes_the_question(self):
        # Stopped before the rule existed: the next listing, or «Seguir desde aquí», asks the datum.
        entry = self.errand()
        errands.update(self.home, entry["id"], status="stuck", blocked={"kind": "other"},
                       reason="Prozis exige una fecha de nacimiento para crear la cuenta y no permite continuar sin ella.")
        self.assertEqual(errands.convert_datum_stops(self.home), [entry["id"]])
        saved = errands.get(self.home, entry["id"])
        self.assertEqual((saved["status"], saved["questions"]["items"][0]["id"]), ("needs_input", "birthdate"))
        self.assertEqual(errands.convert_datum_stops(self.home), [])
        other = self.errand()
        errands.update(self.home, other["id"], status="stuck", reason="Hace falta el DNI para la factura.")
        with mock.patch.object(errands, "launch") as launched, mock.patch.object(errands, "_goal_manager"):
            went = errands.go_on(self.home, other["id"])
        self.assertEqual((went["status"], went["questions"]["items"][0]["id"]), ("needs_input", "id"))
        self.assertFalse(launched.called)

    def test_anything_else_that_stops_it_is_not_a_price(self):
        self.assertEqual(errands.blocked_by("la variante sin sabor ya no está disponible"), {"kind": "gone"})
        self.assertEqual(errands.blocked_by("la página da error al pagar"), {"kind": "other"})
        self.assertEqual(errands.blocked_by("precio 1.234,56 € en la cesta")["price"], "1.234,56 €")

    def test_a_catalog_option_opens_its_cart_link(self):
        offer = {"option_id": "a1b2c3d4-1", "title": "Camiseta", "merchant": "Minimalism", "variant": "Blanca / S",
                 "qty": 1, "price": "25,00 €", "currency": "EUR", "channel": "catalog",
                 "url": "https://minimalismbrand.com/products/camiseta", "checkout_url": "https://minimalismbrand.com/cart/1:1"}
        entry = errands.create(self.home, "Comprar Camiseta", now=NOW, offer=offer)
        self.assertIn("https://minimalismbrand.com/cart/1:1", errands.brief(entry))

    def test_the_same_option_is_one_errand_while_it_is_active(self):
        offer = {"option_id": "a1b2c3d4-1", "url": "https://shop.example/p", "title": "P", "price": "1 €"}
        with mock.patch.object(errands, "launch"), mock.patch.object(errands, "open_goal"):
            first = errands.start(self.home, {"task": "Comprar P", "title": "P"}, origin_session="chat-1", offer=offer)
            again = errands.start(self.home, {"task": "Comprar P otra vez", "title": "P"}, origin_session="chat-1",
                                  offer=offer)
            other = errands.start(self.home, {"task": "Comprar P", "title": "P"}, origin_session="chat-1",
                                  offer={**offer, "option_id": "a1b2c3d4-2"})
        self.assertEqual(first["errand_id"], again["errand_id"])
        self.assertNotEqual(first["errand_id"], other["errand_id"])
        self.assertEqual(errands.get(self.home, first["errand_id"])["offer"]["option_id"], "a1b2c3d4-1")


class RestartTests(Base):
    def test_a_restarted_engine_waits_for_the_run_still_going(self):
        entry = self.errand()
        errands.update(self.home, entry["id"], run_id="run_old")
        gateway = FakeGateway([done("Seguimos")])
        polls = [{"status": "running"}, {"status": "completed", "output": "Hecho"}]
        original = gateway.status
        gateway.status = lambda run_id: polls.pop(0) if run_id == "run_old" and polls else original(run_id)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run("[Continuing toward your standing goal] reinicio"), "done")
        # Only one new run, after the old one ended, with a plain continuation.
        self.assertEqual(len(gateway.started), 1)
        self.assertEqual(gateway.started[0][1], errands.CONTINUATION)

    def test_a_restarted_engine_still_delivers_the_persons_answer(self):
        # The service restarted while the agent's run went on; meanwhile the person approved.
        entry = self.errand()
        errands.update(self.home, entry["id"], run_id="run_old", runs=3)
        gateway = FakeGateway([done("Pagado")])
        polls = [{"status": "running"}, {"status": "completed", "output": "Esperando"}]
        original = gateway.status
        gateway.status = lambda run_id: polls.pop(0) if run_id == "run_old" and polls else original(run_id)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run("[checkout aprobado] paga 27,98 €"), "done")
        self.assertEqual(gateway.started[0][1], "[checkout aprobado] paga 27,98 €")


class DeliveryTests(Base):
    """The delivery details are asked once, all together, before the shop (Muse's playbook, §11.2)."""
    OFFER = {"option_id": "a1b2c3d4-1", "title": "Creatina", "merchant": "Prozis", "qty": 1, "price": "24,49 €",
             "currency": "EUR", "url": "https://www.prozis.com/c", "channel": "browser"}

    def setUp(self):
        super().setUp()
        self.addCleanup(setattr, errands, "details_block", errands.details_block)

    def start(self, details, session="chat-1"):
        errands.details_block = lambda profile: details
        with mock.patch.object(errands, "launch", return_value=True) as launched, mock.patch.object(errands, "open_goal"):
            out = errands.start(self.home, {"task": "Comprar creatina"}, origin_session=session, offer=self.OFFER)
        return errands.get(self.home, out["errand_id"]), launched

    def test_missing_delivery_details_are_asked_before_a_single_page_opens(self):
        entry, launched = self.start({"name": "Marc", "postcode": "08260"})
        self.assertEqual(entry["status"], "needs_input")
        self.assertFalse(launched.called)
        asked = entry["questions"]
        self.assertTrue(asked["fields"])
        self.assertEqual([q["id"] for q in asked["items"]], ["surname", "address", "city", "phone", "email"])
        self.assertIn("Datos de envío", asked["title"])

    def test_complete_or_unreadable_details_ask_nothing(self):
        full = {field: "x" for field, _ in errands.DELIVERY_FIELDS}
        entry, launched = self.start(full)
        self.assertEqual((entry["status"], launched.called), ("working", True))
        entry, launched = self.start(None, session="chat-2")
        self.assertEqual((entry["status"], launched.called), ("working", True))

    def test_the_first_run_reads_the_brief_with_the_answers_and_the_kept_details(self):
        errands.details_block = lambda profile: {"name": "Marc", "address": "Carrer Major 1", "postcode": "08260",
                                                  "city": "Súria", "phone": "600000000", "email": "m@example.com",
                                                  "surname": "F."}
        entry = errands.create(self.home, "Comprar creatina", now=NOW, offer=self.OFFER)
        gateway = FakeGateway([done("Pedido 1 realizado")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run("[respuesta:phone] 600000000"), "done")
        first = gateway.started[0][1]
        self.assertTrue(first.startswith("[Recado de Alice]"))
        self.assertIn("Carrer Major 1", first)
        self.assertIn("sin preguntarlos", first)
        self.assertTrue(first.endswith("[respuesta:phone] 600000000"))


class CirclingTests(Base):
    def steps(self, entry, n, url, start=NOW, gap=30):
        for i in range(n):
            errands.add_step(self.home, entry["id"], f"Paso {i}", url, now=start + i * gap)

    def test_many_steps_on_one_page_for_minutes_is_going_round(self):
        entry = self.errand()
        self.steps(entry, errands.CIRCLE_STEPS, "https://secure.store.apple.com/es/shop/checkout?_s=Shipping-init")
        self.assertEqual(errands.circling(errands.get(self.home, entry["id"])), "secure.store.apple.com/es/shop/checkout")

    def test_moving_on_or_being_quick_is_not(self):
        entry = self.errand()
        self.steps(entry, errands.CIRCLE_STEPS, "https://shop.es/checkout", gap=5)
        self.assertIsNone(errands.circling(errands.get(self.home, entry["id"])))
        other = self.errand()
        self.steps(other, errands.CIRCLE_STEPS - 1, "https://shop.es/checkout")
        errands.add_step(self.home, other["id"], "Pago", "https://shop.es/pago", now=NOW + 999)
        self.assertIsNone(errands.circling(errands.get(self.home, other["id"])))

    def test_the_engine_warns_once_about_a_page_and_stops_the_second_round(self):
        # A one-page checkout (basket, address, delivery and payment on one path) takes many
        # steps there while moving on: the first round is a word to the agent, not a stop.
        entry = self.errand()
        self.steps(entry, errands.CIRCLE_STEPS, "https://shop.es/checkout")
        more = {"n": 0}

        def on_start(n):
            if n == 2:  # the agent goes round again on the same page after the warning
                self.steps(entry, errands.CIRCLE_STEPS, "https://shop.es/checkout", start=NOW + 5000)
        gateway = FakeGateway([[{"status": "running"}], [{"status": "running"}]], on_start=on_start)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(gateway.stopped, ["run_1", "run_2"])
        self.assertIn("misma página", gateway.started[1][1])
        self.assertIn("error", gateway.started[1][1])
        self.assertIn("misma página", errands.get(self.home, entry["id"])["reason"])

    def test_a_page_that_changed_since_the_warning_is_not_going_round(self):
        # Prozis keeps login, address and payment at checkout/index: the state of the page, not
        # its address, says whether the errand moves on.
        entry = self.errand()
        self.steps(entry, errands.CIRCLE_STEPS, "https://www.prozis.com/es/es/checkout/index")
        signatures = iter(["login-form", "address-form", "payment-form"])

        def on_start(n):
            self.steps(entry, errands.CIRCLE_STEPS, "https://www.prozis.com/es/es/checkout/index", start=NOW + 5000 * n)
        gateway = FakeGateway([[{"status": "running"}], [{"status": "running"}], done("Pedido listo")], on_start=on_start)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None, page_signature=lambda e: next(signatures))
        self.assertEqual(engine.run(), "done")
        self.assertEqual(len(gateway.started), 3)
        same = iter(["login-form", "login-form"])
        other = self.errand()
        self.steps(other, errands.CIRCLE_STEPS, "https://www.prozis.com/es/es/checkout/index")
        gateway = FakeGateway([[{"status": "running"}], [{"status": "running"}]],
                              on_start=lambda n: self.steps(other, errands.CIRCLE_STEPS, "https://www.prozis.com/es/es/checkout/index", start=NOW + 5000 * n))
        engine = errands.Engine(self.home, other["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None, page_signature=lambda e: next(same))
        self.assertEqual(engine.run(), "stuck")

    def test_moving_on_after_the_warning_is_not_going_round(self):
        entry = self.errand()
        self.steps(entry, errands.CIRCLE_STEPS, "https://shop.es/checkout")
        gateway = FakeGateway([[{"status": "running"}], done("Pedido listo")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run(), "done")
        self.assertEqual(gateway.stopped, ["run_1"])


class ResumeTests(Base):
    def test_an_answer_given_while_the_run_still_goes_on_is_not_lost(self):
        # The agent called checkout_request but had not ended its turn; the person approved at
        # once. launch cannot start a second engine, so the running one must read the message.
        entry = self.errand()
        lock = errands._engine_lock(self.home, entry["id"])
        self.addCleanup(lock.close)
        with mock.patch.object(errands, "_goal_manager"):
            self.assertFalse(errands.resume(self.home, entry["id"], "[checkout aprobado] paga 27,98 €"))
        saved = errands.get(self.home, entry["id"])
        self.assertEqual((saved["status"], saved["resume_message"]), ("working", "[checkout aprobado] paga 27,98 €"))
        self.assertNotIn("resume_message", errands.public(saved))

    def test_the_running_engine_sends_the_answer_as_its_next_message(self):
        entry = self.errand()

        def approve_meanwhile(n):
            if n == 1:
                errands.update(self.home, entry["id"], resume_message="[checkout aprobado] paga 27,98 €")
        gateway = FakeGateway([done("Esperando la aprobación"), done("Pagado. Pedido 1.")], on_start=approve_meanwhile)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run(), "done")
        self.assertEqual(gateway.started[1][1], "[checkout aprobado] paga 27,98 €")

    def test_a_declined_payment_ends_the_errand_with_its_receipt(self):
        entry = self.errand()

        def decline(n):
            errands.record_receipt(self.home, entry["session_id"], {"site": "hsnstore.com", "outcome": "declined"})
        gateway = FakeGateway([done("El banco rechazó el pago.")], on_start=decline)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway,
                                judge=lambda s, r: {"should_continue": True, "continuation_prompt": "sigue"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run(), "done")
        self.assertEqual(errands.get(self.home, entry["id"])["receipt"]["outcome"], "declined")
        self.assertEqual(len(gateway.started), 1)


class QuestionVettingTests(Base):
    def test_trivial_and_card_questions_never_reach_the_person(self):
        salutation = [{"id": "t", "question": "¿Qué tratamiento prefieres?", "choices": ["Sr.", "Sra."]}]
        self.assertIn("choose it yourself", errands.vet_questions(salutation))
        card = [{"id": "c", "question": "¿Tienes una tarjeta guardada?", "choices": []}]
        self.assertIn("card_request", errands.vet_questions(card))
        colour = [{"id": "c", "question": "¿Qué color quieres?", "choices": ["Burdeos", "Negro"]}]
        self.assertIsNone(errands.vet_questions(colour))

    def test_a_card_request_names_the_payment_pages_origin(self):
        entry = self.errand()
        self.assertFalse(errands.request_card(self.home, entry["id"], "http://insecure.example/pay")["ok"])
        out = errands.request_card(self.home, entry["id"], "https://secure9.store.apple.com/es/shop/checkout?_s=Billing")
        self.assertTrue(out["ok"])
        saved = errands.get(self.home, entry["id"])
        self.assertEqual((saved["status"], saved["card_origin"]), ("needs_card", "https://secure9.store.apple.com"))
        self.assertIn("needs_card", errands.ACTIVE)


class PictureTests(Base):
    def test_a_picture_that_does_not_load_is_replaced_by_the_product_pages_own(self):
        entry = self.errand()
        errands.add_step(self.home, entry["id"], "Ficha", "https://www.apple.com/es/shop/buy-iphone/iphone-18-pro")
        errands.add_step(self.home, entry["id"], "Pago", "https://secure9.store.apple.com/es/shop/checkout")
        good = "https://store.storeimages.cdn-apple.com/real.png"
        page = b'<head><meta property="og:image" content="https://store.storeimages.cdn-apple.com/real.png?a=1&amp;b=2"></head>'

        def fetch(url, limit, accept):
            if url.startswith("https://www.apple.com/es/shop/buy-iphone"):
                return page, "text/html"
            if url.startswith(good):
                return b"\x89PNG" + b"0" * 400, "image/png"
            raise OSError("404")

        items = [{"name": "iPhone", "image": "https://store.storeimages.cdn-apple.com/invented.webp"}]
        out = errands.real_pictures(errands.get(self.home, entry["id"]), items, fetch)
        self.assertEqual(out[0]["image"], good + "?a=1&b=2")

    def test_no_picture_at_all_is_left_empty_not_broken(self):
        entry = self.errand()
        out = errands.real_pictures(entry, [{"name": "X", "image": "https://nope.example/x.jpg"}], offline)
        self.assertEqual(out[0]["image"], "")

    def test_the_card_the_person_chose_travels_with_the_approval(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], {**CHECKOUT, "card_label": ""})
        decided = errands.decide_checkout(self.home, entry["id"], True, card_label="Mastercard ···4444")
        self.assertEqual(decided["checkout"]["card_label"], "Mastercard ···4444")



class ExpiryTests(Base):
    def test_a_checkout_left_waiting_expires_and_cannot_be_approved(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW)
        self.assertEqual(errands.expire_checkouts(self.home, now=NOW + 60), [])
        self.assertEqual(errands.expire_checkouts(self.home, now=NOW + errands.CHECKOUT_TTL + 1), [entry["id"]])
        self.assertEqual(errands.get(self.home, entry["id"])["checkout"]["status"], "expired")
        self.assertIsNone(errands.decide_checkout(self.home, entry["id"], True, now=NOW + errands.CHECKOUT_TTL + 2))

    def test_approving_late_is_refused_even_before_anything_marked_it(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT, now=NOW)
        self.assertIsNone(errands.decide_checkout(self.home, entry["id"], True, now=NOW + 3 * 3600))
        self.assertIn("checkout_request", errands.refresh_message(errands.get(self.home, entry["id"])["checkout"]))


class StuckContextTests(Base):
    def test_a_stuck_errand_keeps_its_page_until_it_is_stale(self):
        # Its card says «open the browser to see what the shop asks» and «Seguir desde aquí» goes
        # on from that basket: closing the page on stuck contradicted both.
        entry = self.errand()
        outcomes = {"n": 0}

        class Fake:
            def __init__(self, home, errand_id, **kw): self.errand_id = errand_id
            def run(self, message=None):
                outcomes["n"] += 1
                return "stuck" if outcomes["n"] == 1 else "done"
        import time as clock

        def finished(n):  # the engine thread may be gone before launch even returns
            deadline = clock.time() + 5
            while clock.time() < deadline and (outcomes["n"] < n or entry["id"] in errands._threads):
                clock.sleep(0.02)
        with mock.patch.object(errands, "release_context") as released:
            self.assertTrue(errands.launch(self.home, entry["id"], engine_factory=Fake))
            finished(1)
            self.assertFalse(released.called)
            self.assertTrue(errands.launch(self.home, entry["id"], engine_factory=Fake))
            finished(2)
            self.assertTrue(released.called)

    def test_stale_stuck_pages_are_released_later(self):
        entry = self.errand()
        errands.update(self.home, entry["id"], now=NOW, status="stuck", reason="x")
        with mock.patch.object(errands, "release_context") as released:
            self.assertEqual(errands.release_stale(self.home, now=NOW + 3600), [])
            self.assertEqual(errands.release_stale(self.home, now=NOW + 3 * 3600), [entry["id"]])
            self.assertEqual(errands.release_stale(self.home, now=NOW + 4 * 3600), [])
        released.assert_called_once_with(entry["id"], home=self.home)


class ContextTests(Base):
    def test_the_preamble_is_valid_code_naming_its_own_file(self):
        code = errands.context_preamble("abc123def0")
        compile(code, "<preamble>", "exec")
        self.assertIn(str(errands.context_file("abc123def0")), code)
        self.assertIn("Target.createBrowserContext", code)
        # A strange id cannot reach the file name.
        self.assertNotIn("..", str(errands.context_file("../../etc")))

    def test_the_preamble_makes_and_then_keeps_one_context_and_tab(self):
        calls = []
        state = {"targets": [], "contexts": []}

        def cdp(method, **params):
            calls.append(method)
            if method == "Target.getTargets":
                return {"targetInfos": [{"targetId": t} for t in state["targets"]]}
            if method == "Target.getBrowserContexts":
                return {"browserContextIds": state["contexts"]}
            if method == "Target.createBrowserContext":
                state["contexts"].append("ctx1")
                return {"browserContextId": "ctx1"}
            if method == "Target.createTarget":
                self.assertEqual(params["browserContextId"], "ctx1")
                state["targets"].append("tab1")
                return {"targetId": "tab1"}
            return {}

        switched = []
        errand_id = "a1b2c3d4e5"
        self.addCleanup(lambda: errands.context_file(errand_id).unlink(missing_ok=True))
        code = errands.context_preamble(errand_id)
        exec(code, {"cdp": cdp, "switch_tab": switched.append, "capture_screenshot": lambda: "fixture.png"})
        exec(code, {"cdp": cdp, "switch_tab": switched.append, "capture_screenshot": lambda: "fixture.png"})
        self.assertEqual(switched, ["tab1", "tab1"], "Every call must restore the errand's own tab")
        self.assertEqual(calls.count("Target.createBrowserContext"), 1)

    def test_a_failure_to_isolate_never_runs_in_someone_elses_context(self):
        def broken(method, **params):
            raise RuntimeError("no CDP")

        self.addCleanup(lambda: errands.context_file("ffff000011").unlink(missing_ok=True))
        visited = []
        with self.assertRaisesRegex(RuntimeError, "No se pudo aislar"):
            exec(errands.context_preamble("ffff000011") + "\nvisited.append('wrong basket')",
                 {"cdp": broken, "switch_tab": lambda t: None, "visited": visited})
        self.assertEqual(visited, [])

    def test_releasing_disposes_the_context_and_forgets_it(self):
        path = errands.context_file("0a0b0c0d0e")
        path.write_text(json.dumps({"context": "ctx9", "target": "t"}))
        sent = []

        class Socket:
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def send(self, text): sent.append(json.loads(text))
            def recv(self, timeout=None): return "{}"

        with mock.patch("websockets.sync.client.connect", return_value=Socket()):
            self.assertTrue(errands.release_context("0a0b0c0d0e", browser_ws="ws://x"))
        self.assertEqual(sent[0]["method"], "Target.disposeBrowserContext")
        self.assertEqual(sent[0]["params"]["browserContextId"], "ctx9")
        self.assertFalse(path.exists())
        self.assertFalse(errands.release_context("0a0b0c0d0e", browser_ws="ws://x"))

class AnswerTests(unittest.TestCase):
    def test_answers_become_the_lines_ask_person_reads(self):
        text = errands.answer_text({"size": "500 g", "flavour": "Sin sabor", "bad id!": "x"})
        self.assertEqual(text.splitlines(), ["[respuesta:size] 500 g", "[respuesta:flavour] Sin sabor",
                                             "[respuesta:badid] x"])


if __name__ == "__main__":
    unittest.main()


class CartStepTests(unittest.TestCase):
    def test_finalizar_compra_passes_only_on_a_page_read_without_payment(self):
        click = {"code": "click button «Finalizar compra»"}
        self.assertTrue(errands.is_pay_action("browser_exec", click))                      # unread: blocked
        self.assertTrue(errands.is_pay_action("browser_exec", click, payment_step=True))  # payment shown
        self.assertFalse(errands.is_pay_action("browser_exec", click, payment_step=False))
        self.assertTrue(errands.is_pay_action("browser_exec", {"code": "click Pagar"}, payment_step=False))
        self.assertTrue(errands.is_pay_action("browser_exec", click, "https://s.test/checkout/payment", False))


class DialogTests(unittest.TestCase):
    def run_preamble(self, dialog, call=""):
        code = errands.context_preamble("e-test")
        start = code.index("# alice: a page alert")
        handled = []
        env = {"page_info": lambda: {"dialog": dialog} if dialog else {"url": "x"},
               "cdp": lambda method, **kw: handled.append(kw.get("accept"))}
        exec(code[start:] + call, env)  # noqa: S102 — the preamble's own text
        return handled

    def test_an_alert_is_closed_before_the_step(self):
        self.assertEqual(self.run_preamble({"type": "alert", "message": "Obligatorio"}), [True])
        self.assertEqual(self.run_preamble(None), [])

    def test_a_confirm_that_orders_is_never_accepted(self):
        order = {"type": "confirm", "message": "¿Realizar pedido ahora?"}
        self.assertEqual(self.run_preamble(order, "\nclose_dialog(accept=True)"), [False, False])
        removal = {"type": "confirm", "message": "¿Eliminar este producto?"}
        self.assertEqual(self.run_preamble(removal, "\nclose_dialog(accept=True)"), [False, True])


class BasketUnitsTests(unittest.TestCase):
    def test_extra_units_are_the_agents_to_fix_not_a_price(self):
        offer = {"price": "29,99 €", "currency": "EUR"}
        said = "la cesta tiene 2 unidades por 59,98 €; el precio y la cantidad no coinciden"
        self.assertEqual(errands.blocked_by(said, offer)["kind"], "other")
        self.assertEqual(errands.blocked_by("precio 59,98 €", offer)["kind"], "other")
        self.assertEqual(errands.blocked_by("precio 34,99 € — subió", offer),
                         {"kind": "price", "price": "34,99 €"})


class PaymentMethodTests(Base):
    """P0: a shop paid by PayPal, Bizum or a card it keeps needs no card in the vault, and the
    approval says how it is paid."""

    def test_paying_without_a_saved_card_needs_none_when_the_shop_is_paid_another_way(self):
        entry = self.errand()
        out = errands.request_checkout(self.home, entry["id"], {**CHECKOUT, "card_label": "", "payment_method": "paypal"},
                                       now=NOW, saved_cards=lambda: [])
        self.assertEqual(out["status"], "needs_approval")
        checkout = errands.get(self.home, entry["id"])["checkout"]
        self.assertEqual((checkout["payment_method"], checkout["card_label"]), ("paypal", ""))
        message = errands.approved_message(errands.decide_checkout(self.home, entry["id"], True, now=NOW + 1)["checkout"])
        self.assertIn("PayPal", message)
        self.assertIn("unknown", message)
        self.assertNotIn("tarjeta guardada", message)

    def test_a_card_payment_still_asks_for_a_card_first(self):
        entry = self.errand()
        for method in ("card", "", "something_else"):
            with self.subTest(method=method):
                out = errands.request_checkout(self.home, entry["id"], {**CHECKOUT, "payment_method": method},
                                               now=NOW, saved_cards=lambda: [])
                self.assertEqual(out["status"], "needs_card")

    def test_a_press_that_pays_by_itself_is_strong_a_continue_is_not(self):
        banks = {"sis.redsys.es"}
        self.assertTrue(errands.is_strong_pay_action("browser_click", {"text": "Pagar ahora"}, "https://shop.es/checkout", banks))
        self.assertTrue(errands.is_strong_pay_action("browser_exec", {"code": "click('#pay')"},
                                                     "https://sis.redsys.es/sis/realizarPago", banks))
        self.assertFalse(errands.is_strong_pay_action("browser_click", {"text": "Continuar"},
                                                      "https://shop.es/checkout/payment", banks))
        self.assertFalse(errands.is_strong_pay_action("browser_exec", {"code": "print(page_info())"},
                                                      "https://sis.redsys.es/sis/realizarPago", banks))

    def test_the_pay_gate_names_the_one_approval_window(self):
        entry = self.errand()
        verdict = errands.pay_gate(self.home, entry["session_id"], tool_name="browser_click", args={"text": "Pagar ahora"})
        self.assertIn(f"{errands.APPROVAL_TTL // 60} minutos", verdict["message"])
        self.assertNotIn("10 minutos", verdict["message"])

    def test_the_offer_lines_carry_the_coupon_the_price_rests_on(self):
        lines = errands._offer_lines({"title": "Creapure", "url": "https://shop.es/p", "price": "31,49 €", "coupon": "PUBLIC10"})
        self.assertIn("«PUBLIC10»", lines)
        self.assertIn("purchase_check_cart", lines)
        self.assertNotIn("cupón", errands._offer_lines({"title": "Creapure", "url": "https://shop.es/p", "price": "31,49 €"}))


class OutcomeEngineTests(Base):
    """P0: once money may be out, «done» needs its outcome; whatever stops the errand first writes
    that outcome as unknown, in the ledger and on the card."""

    def approved(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT)
        errands.decide_checkout(self.home, entry["id"], True)
        return entry

    def test_done_with_a_payment_out_is_asked_twice_then_ends_unknown(self):
        entry = self.approved()
        gateway = FakeGateway([done("Pagado."), done("Pagado, ya está."), done("Hecho.")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"}, sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(len(gateway.started), 3)
        self.assertIn("purchase_outcome", gateway.started[1][1])
        saved = errands.get(self.home, entry["id"])
        self.assertEqual(saved["receipt"]["outcome"], "unknown")
        self.assertIn("No se pudo confirmar", saved["reason"])
        ledger = errands._purchases()
        self.assertEqual(ledger._read(ledger._ledger(self.home))[-1]["status"], "unknown")

    def test_done_after_the_outcome_was_written_is_done(self):
        entry = self.approved()

        def on_start(n):
            errands.record_receipt(self.home, entry["session_id"], {"site": "hsnstore.com", "outcome": "paid", "order": "1"})

        gateway = FakeGateway([done("Pagado.")], on_start=on_start)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"}, sleep=lambda s: None)
        self.assertEqual(engine.run(), "done")

    def test_done_without_any_payment_is_done(self):
        entry = self.errand()
        gateway = FakeGateway([done("No se encontró.")])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"}, sleep=lambda s: None)
        self.assertEqual(engine.run(), "done")

    def test_a_failure_after_approval_closes_the_payment_as_unknown(self):
        entry = self.approved()
        gateway = FakeGateway([[{"status": "failed", "error": "Model timeout"}]])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"}, sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        saved = errands.get(self.home, entry["id"])
        self.assertEqual(saved["receipt"]["outcome"], "unknown")
        self.assertIn("Model timeout", saved["reason"])
        self.assertTrue(saved["reason"].startswith("No se pudo confirmar"))

    def test_a_failure_before_approval_says_nothing_about_payments(self):
        entry = self.errand()
        gateway = FakeGateway([[{"status": "failed", "error": "Model timeout"}]])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"}, sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        saved = errands.get(self.home, entry["id"])
        self.assertIsNone(saved.get("receipt"))
        self.assertEqual(saved["reason"], "Model timeout")

    def test_an_unknown_receipt_stops_the_errand_on_it(self):
        entry = self.approved()

        def on_start(n):
            errands.record_receipt(self.home, entry["session_id"], {"site": "hsnstore.com", "outcome": "unknown"})

        gateway = FakeGateway([done("No sé si se cobró.")], on_start=on_start)
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"}, sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertIn("No se pudo confirmar", errands.get(self.home, entry["id"])["reason"])

    def test_a_judge_that_fails_twice_leaves_it_stuck_not_running_blind(self):
        entry = self.errand()
        gateway = FakeGateway([done("a"), done("b"), done("c")])

        def judge(session_id, reply):
            raise RuntimeError("judge down")

        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=judge, sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(len(gateway.started), 2)
        self.assertIn("juzgar", errands.get(self.home, entry["id"])["reason"])


class PayAgainTests(Base):
    """P0: a shop paid before stops the errand; only the person's word lets one more payment through."""

    def test_seguir_on_a_paid_before_stop_allows_one_payment_within_the_window(self):
        entry = self.errand()
        errands.update(self.home, entry["id"], status="stuck", reason="Ya se pagó un pedido en hsnstore.com hace 5 min.",
                       blocked={"kind": "paid_before", "shop": "hsnstore.com"})
        with mock.patch.object(errands, "launch", return_value=True):
            resumed = errands.go_on(self.home, entry["id"])
        self.assertEqual(resumed["status"], "working")
        self.assertIsNone(resumed.get("blocked"))
        self.assertGreater(float(resumed["pay_again_until"]), time.time())
        self.assertLessEqual(float(resumed["pay_again_until"]), time.time() + errands.APPROVAL_TTL + 1)
        self.assertIn("[pagar otra vez]", resumed["resume_message"])
        self.assertNotIn("pay_again_until", errands.public(resumed))

    def test_seguir_on_an_unknown_payment_checks_and_never_pays(self):
        entry = self.errand()
        errands.record_receipt(self.home, entry["session_id"], {"site": "hsnstore.com", "outcome": "unknown"})
        errands.update(self.home, entry["id"], status="stuck", reason=errands.UNKNOWN_REASON)
        with mock.patch.object(errands, "launch", return_value=True):
            resumed = errands.go_on(self.home, entry["id"])
        self.assertEqual(resumed["status"], "working")
        self.assertIn("[comprobar pago]", resumed["resume_message"])
        self.assertIn("No vuelvas a pagar", resumed["resume_message"])
        self.assertIsNone(resumed.get("receipt"))


class RecoveryTests(Base):
    """P2: state that survives a restart, a closed Chrome, a forgotten page and a broken file."""

    def test_the_context_note_lives_under_the_hermes_home_and_an_old_one_moves_there(self):
        legacy = errands.legacy_context_file("0a0b0c0d0e")
        legacy.write_text('{"context": "c", "target": "t"}')
        self.addCleanup(lambda: legacy.unlink(missing_ok=True))
        path = errands.context_file("0a0b0c0d0e", self.home)
        self.assertEqual(path.parent, self.home / ".alice" / "errands")
        self.assertEqual(json.loads(path.read_text())["context"], "c")
        self.assertFalse(legacy.exists())

    def test_the_preamble_notes_a_context_that_had_to_be_made_again(self):
        code = errands.context_preamble("0a0b0c0d0e")
        self.assertIn('_saved["lost"] = True', code)
        compile(code, "preamble", "exec")

    def test_denying_closes_the_errands_page(self):
        entry = self.errand()
        errands.request_checkout(self.home, entry["id"], CHECKOUT)
        with mock.patch.object(errands, "release_context") as released:
            errands.decide_checkout(self.home, entry["id"], False)
        released.assert_called_once_with(entry["id"], home=self.home)

    def test_a_page_waiting_for_the_person_for_half_a_day_is_closed_but_an_approved_one_is_kept(self):
        waiting = self.errand()
        errands.update(self.home, waiting["id"], now=NOW, status="needs_input")
        approved = self.errand()
        errands.request_checkout(self.home, approved["id"], CHECKOUT, now=NOW)
        errands.decide_checkout(self.home, approved["id"], True, now=NOW)
        errands.update(self.home, approved["id"], now=NOW, status="needs_input")
        with mock.patch.object(errands, "release_context") as released:
            self.assertEqual(errands.release_stale(self.home, now=NOW + 3600), [])
            self.assertEqual(errands.release_stale(self.home, now=NOW + errands.STALE_WAITING + 1), [waiting["id"]])
        released.assert_called_once_with(waiting["id"], home=self.home)

    def test_the_engine_waits_while_the_person_holds_the_browser(self):
        entry = self.errand()
        held = [True, True, False]
        gateway = FakeGateway([done("Hecho")])
        naps = []
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=naps.append)
        with mock.patch.object(errands, "_browser_held", side_effect=lambda home: held.pop(0) if held else False):
            self.assertEqual(engine.run(), "done")
        self.assertEqual(naps[:2], [5, 5])
        self.assertEqual(len(gateway.started), 1)

    def test_handing_the_browser_back_tells_running_errands_and_holds_an_approved_payment(self):
        running = self.errand()
        errands.update(self.home, running["id"], status="working")
        approved = self.errand()
        errands.request_checkout(self.home, approved["id"], CHECKOUT)
        errands.decide_checkout(self.home, approved["id"], True)
        waiting = self.errand()
        errands.update(self.home, waiting["id"], status="needs_input")
        told = errands.handed_back(self.home)
        self.assertEqual(set(told), {running["id"], approved["id"]})
        self.assertIn("relee la página", errands.get(self.home, running["id"])["resume_message"])
        self.assertIn("No vuelvas a pagar", errands.get(self.home, approved["id"])["resume_message"])
        self.assertIsNone(errands.get(self.home, waiting["id"]).get("resume_message"))
        ledger = errands._purchases()
        self.assertEqual(ledger.open_payment(self.home, approved["session_id"])["shop"], "hsnstore.com")
        self.assertIsNone(ledger.open_payment(self.home, running["session_id"]))

    def test_the_sweep_runs_every_part_even_when_one_fails(self):
        with mock.patch.object(errands, "expire_checkouts", side_effect=RuntimeError("x")), \
                mock.patch.object(errands, "release_stale", return_value=["a"]) as stale, \
                mock.patch.object(errands, "convert_datum_stops", return_value=[]), \
                mock.patch.object(errands, "ensure_running", return_value=["b"]):
            done = errands.sweep(self.home)
        self.assertEqual(done, {"expired": [], "released": ["a"], "asked": [], "resumed": ["b"]})
        stale.assert_called_once()

    def test_an_unreadable_store_is_set_aside_never_overwritten(self):
        path = errands._path(self.home)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{not json")
        self.assertEqual(errands.listing(self.home), [])
        kept = list(path.parent.glob(path.name + ".corrupt-*"))
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0].read_text(), "{not json")
