"""Errands run apart from the chat, and nothing is paid without the person's approved checkout.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

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


class Base(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())

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
        self.assertNotIn("origin_session", shown)
        self.assertNotIn("run_id", shown["approval"])


class CheckoutTests(Base):
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
        self.current = []

    def start(self, session_id, text):
        if self.fail:
            raise OSError("connection refused")
        self.started.append((session_id, text))
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
        gateway = FakeGateway([done(same), done(same)])
        entry, engine, _ = self.engine(gateway, [dict(keep), dict(keep)])
        self.assertEqual(engine.run(), "stuck")
        self.assertIn("Repetía", errands.get(self.home, entry["id"])["reason"])

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
        out = errands.start(self.home, {"task": "Compra un iPhone 256 GB", "title": "iPhone"},
                            origin_session="chat-1", now=NOW + 60)
        self.assertEqual(out["errand_id"], first["id"])
        self.assertEqual(len(errands.listing(self.home)), 1)

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

    def test_a_chat_turn_asking_for_a_purchase_is_an_errand_request(self):
        self.assertTrue(errands.is_errand_request("compra un iphone 18 pro max"))
        self.assertTrue(errands.is_errand_request("Pídeme el pienso de siempre"))
        self.assertFalse(errands.is_errand_request("abre news.ycombinator.com y dame 3 titulares"))
        self.assertFalse(errands.is_errand_request("[respuesta:size] 256 GB"))
        self.assertIn("errand_start", errands.brief({"request": "x"}))
        self.assertIn("nunca llames a `errand_start`", errands.brief({"request": "x"}))

class AnswerTests(unittest.TestCase):
    def test_answers_become_the_lines_ask_person_reads(self):
        text = errands.answer_text({"size": "500 g", "flavour": "Sin sabor", "bad id!": "x"})
        self.assertEqual(text.splitlines(), ["[respuesta:size] 500 g", "[respuesta:flavour] Sin sabor",
                                             "[respuesta:badid] x"])


if __name__ == "__main__":
    unittest.main()
