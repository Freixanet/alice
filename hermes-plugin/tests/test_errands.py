"""Errands run apart from the chat, and nothing is paid without the person's approved checkout.

    PYTHONPATH=~/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
"""
import importlib.util
import concurrent.futures
import json
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

    def test_a_chat_turn_asking_for_a_purchase_is_an_errand_request(self):
        self.assertTrue(errands.is_errand_request("compra un iphone 18 pro max"))
        self.assertTrue(errands.is_errand_request("Pídeme el pienso de siempre"))
        self.assertFalse(errands.is_errand_request("abre news.ycombinator.com y dame 3 titulares"))
        self.assertFalse(errands.is_errand_request("[respuesta:size] 256 GB"))
        self.assertIn("errand_start", errands.brief({"request": "x"}))
        self.assertIn("nunca llames a `errand_start`", errands.brief({"request": "x"}))


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

    def test_the_engine_stops_a_run_going_round_and_says_why(self):
        entry = self.errand()
        self.steps(entry, errands.CIRCLE_STEPS, "https://shop.es/checkout")
        gateway = FakeGateway([[{"status": "running"}]])
        engine = errands.Engine(self.home, entry["id"], gateway=gateway, judge=lambda s, r: {"status": "done"},
                                sleep=lambda s: None)
        self.assertEqual(engine.run(), "stuck")
        self.assertEqual(gateway.stopped, ["run_1"])
        self.assertIn("misma página", errands.get(self.home, entry["id"])["reason"])


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
        exec(code, {"cdp": cdp, "switch_tab": switched.append})
        exec(code, {"cdp": cdp, "switch_tab": switched.append})
        self.assertEqual(switched, ["tab1"])
        self.assertEqual(calls.count("Target.createBrowserContext"), 1)

    def test_a_failure_to_isolate_never_stops_the_errand(self):
        def broken(method, **params):
            raise RuntimeError("no CDP")

        self.addCleanup(lambda: errands.context_file("ffff000011").unlink(missing_ok=True))
        exec(errands.context_preamble("ffff000011"), {"cdp": broken, "switch_tab": lambda t: None})

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
