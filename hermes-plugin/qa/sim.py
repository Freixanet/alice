"""A whole purchase, end to end, with the real plugin and no money, shop, model or person.

What is real: the plugin (`__init__.py`, loaded and registered as Hermes does, with every hook in
its order), the errand engine (`errands.Engine`), the price service, the shop engine, the ledger,
the dashboard routes the iPhone calls (`dashboard/plugin_api.py`, through FastAPI's TestClient) and
the pages' own JavaScript (jsdom, `tests/fixtures/js_page.cjs`).

What is simulated:

* **the model** — `Robot`, a scripted agent that follows the `comprar` skill and calls the plugin's
  tools and browser actions through the same hook pipeline Hermes runs (pre_tool_call →
  the tool → transform_tool_result → post_tool_call), and obeys a block as a model would;
* **the person** — `Person`, who answers through the dashboard routes: approve, deny, answer,
  add a card, «Seguir», accept a new price;
* **the shops** — three fictional shops (`tests/fixtures/shops.py`), a fresh copy per browser
  context so a disposable cart never sees the errand's basket;
* **Hermes** — a `hermes_constants` module pointing at a temporary home, and a gateway that runs
  the robot's turn instead of a model.

Faults (`FAULTS`) are injected at named points. The oracle (`oracle.py`) checks the invariants
after every event. `run(shop, faults)` returns a report; nothing touches a real Hermes, browser,
shop or account.
"""
from __future__ import annotations

import contextlib
import copy
import importlib.util
import json
import re
import sys
import tempfile
import time
import traceback
import types
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence
from unittest import mock

PLUGIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN / "tests" / "fixtures"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import shops  # noqa: E402
from oracle import Oracle  # noqa: E402

CHAT = "20261002_120000_000001"
CARD_LABEL = "Visa ···0002"
CASES = {
    "tienda-tres.example": {"shop": "Generic", "query": "zapatillas trail", "variant": "43", "qty": 2, "merchant": "Tienda Tres"},
    "tienda-uno.example": {"shop": "ShopifyLike", "query": "creatina creapure", "variant": "500 g", "qty": 1, "merchant": "Tienda Uno"},
    "tienda-dos.example": {"shop": "WooLike", "query": "proteina whey", "variant": "Vainilla", "qty": 1, "merchant": "Tienda Dos"},
}
FAULTS = (
    "price_changed", "sold_out_after_choice", "total_changed_before_paying", "denied", "double_approval", "declined",
    "outcome_never_written", "judge_down_after_approval", "chrome_crash_before_paying", "pay_twice",
    "no_delivery_details", "no_saved_card", "ledger_unwritable", "agent_pays_without_approval",
)
# What each scenario must end as, besides every invariant holding.
EXPECTED = {
    (): ("done", "paid"),
    ("price_changed",): ("done", "paid"),          # the person accepts the new price
    ("sold_out_after_choice",): ("stuck", None),
    ("total_changed_before_paying",): ("done", "paid"),  # asked again, approved again
    ("denied",): ("denied", None),
    ("double_approval",): ("done", "paid"),
    ("declined",): ("done", "declined"),
    ("outcome_never_written",): ("stuck", "unknown"),
    ("judge_down_after_approval",): (None, None),  # any end, as long as the invariants hold
    ("chrome_crash_before_paying",): ("done", "paid"),
    ("pay_twice",): ("done", "paid"),
    ("no_delivery_details",): ("done", "paid"),
    ("no_saved_card",): ("done", "paid"),
    ("ledger_unwritable",): (None, None),
    ("agent_pays_without_approval",): ("done", "paid"),
}


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class World:
    """The shops as they are now: faults change them for every browser context opened afterwards."""

    def __init__(self, case: Dict[str, Any]):
        self.case = case
        self.price_delta = 0
        self.sold_out = False

    def shop(self) -> shops.Shop:
        cls = getattr(shops, self.case["shop"])
        shop = cls()
        variant = self.case["variant"]
        if isinstance(shop, shops.Generic):
            shop.PRODUCTS = copy.deepcopy(cls.PRODUCTS)
            for product in shop.PRODUCTS.values():
                for size, cents in list(product["sizes"].items()):
                    if cents is not None:
                        product["sizes"][size] = None if (self.sold_out and size == variant) else cents + self.price_delta
                if "price" in product:
                    product["price"] += self.price_delta
        elif isinstance(shop, shops.ShopifyLike):
            shop.PRODUCTS = copy.deepcopy(cls.PRODUCTS)
            for product in shop.PRODUCTS:
                for v in product["variants"]:
                    v["price"] += self.price_delta
                    if self.sold_out and v["title"] == variant:
                        v["available"] = False
        elif isinstance(shop, shops.WooLike):
            shop.VARIATIONS = copy.deepcopy(cls.VARIATIONS)
            for v in shop.VARIATIONS:
                v["price"] += self.price_delta
                if self.sold_out and v["label"] == variant:
                    v["stock"] = False
        return shop

    def router(self) -> shops.Router:
        return shops.Router(self.shop(), Bank())


class Bank(shops.Shop):
    host = "sis.redsys.es"

    def request(self, method, url, body=""):
        return shops.html("<h1>Pago seguro</h1><input name=cardNumber autocomplete=cc-number>"
                          "<button type=button onclick='window.paid=true'>Pagar</button>")


class Card(types.SimpleNamespace):
    pass


class Cards:
    """The vault as the plugin sees it: card labels and origins, never a number."""
    PAYMENT_GATEWAYS = {"sis.redsys.es"}

    def __init__(self, origin: str, saved: bool = True):
        self.items = {"card-1": Card(id="card-1", kind="payment", origin=origin, label=CARD_LABEL)} if saved else {}

    def cards(self):
        return [{"label": c.label, "origin": c.origin} for c in self.items.values()]

    def _store(self):
        items = self.items
        return types.SimpleNamespace(get_meta=lambda handle: items.get(handle), list_items=lambda: list(items.values()))

    @staticmethod
    def identity(label):
        return " ".join(str(label or "").split()).casefold()

    @staticmethod
    def route_fill(handle, urls):
        return None

    @staticmethod
    def prompt(profile):
        return ""


class Gateway:
    """Hermes' /v1/runs, with the robot's turn instead of a model's."""

    def __init__(self, sim: "Sim"):
        self.sim = sim
        self.runs: Dict[str, Dict[str, Any]] = {}

    def start(self, session_id, text, *, model, provider):
        run = f"run-{len(self.runs) + 1}"
        try:
            output = self.sim.robot.errand_turn(session_id, text)
            self.runs[run] = {"status": "completed", "output": output}
        except Exception as exc:  # noqa: BLE001 — the robot's crash is the simulator's bug, said as such
            self.sim.oracle.fail("SIM", "robot", "el agente simulado falló: " + "".join(traceback.format_exception_only(exc)).strip())
            self.runs[run] = {"status": "failed", "error": "simulator"}
        return run

    def status(self, run_id):
        return self.runs.get(run_id) or {"status": "completed", "output": ""}

    def approve(self, run_id, choice, request_id=""):
        return True

    def stop(self, run_id):
        pass


class Sim:
    def __init__(self, shop: str = "tienda-tres.example", faults: Sequence[str] = (), seed: int = 0):
        unknown = [f for f in faults if f not in FAULTS]
        if unknown:
            raise ValueError("faltas desconocidas: " + ", ".join(unknown))
        self.case = {**CASES[shop], "host": shop}
        self.faults = tuple(faults)
        self.seed = seed
        self.world = World(self.case)
        self.events: List[str] = []
        self.session = ""
        self.launches: List[tuple] = []
        self.pages: List[shops.JsPage] = []
        self.errand_js: Optional[shops.JsPage] = None
        self.ctx = ""
        self.contexts = 0
        self.once: set = set()

    def fault(self, name: str, once: bool = True) -> bool:
        """Whether this fault is on; with ``once``, true only the first time it is asked."""
        if name not in self.faults:
            return False
        if not once:
            return True
        if name in self.once:
            return False
        self.once.add(name)
        return True

    # ── Setting up the real plugin around a temporary Hermes ─────────────────────

    def __enter__(self):
        self.stack = contextlib.ExitStack()
        self.home = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix="alice-qa-")))
        (self.home / ".alice").mkdir()
        (self.home / ".alice" / "errand-model.json").write_text('{"model": "sim-robot", "provider": "sim"}')
        hermes = types.ModuleType("hermes_constants")
        hermes.get_hermes_home = lambda: self.home
        self.stack.enter_context(mock.patch.dict(sys.modules, {"hermes_constants": hermes}))
        self.plugin = load("alice_qa_plugin", PLUGIN / "__init__.py")
        p = self.plugin
        self.errands = p._errands()
        self.flow = p._purchase_flow()
        self.purchases = p._purchases()
        self.prices = p._module("purchase_prices.py", "alice_purchase_prices")
        self.access = p._module("errand_access.py", "alice_errand_access")
        self.engine = p._module("shop_engine.py", "alice_shop_engine")
        self.ask = p._ask_person()
        live = p._browser()
        self.cards = Cards("https://" + self.case["host"], saved="no_saved_card" not in self.faults)
        patch = lambda target, name, value: self.stack.enter_context(mock.patch.object(target, name, value))
        patch(p, "_hermes_root", lambda: self.home)
        patch(p, "_session_id", lambda session_id="": str(session_id or self.session))
        patch(p, "_cards_module", lambda: self.cards)
        patch(p, "_open_tabs", lambda: [self.url()])
        patch(p, "_active_url", lambda: self.url())
        patch(p, "_schedule_payment_check", lambda entry: None)
        patch(p, "_start_feed", lambda *a, **k: None)
        for name, value in (("managed", lambda root: False), ("ensure", lambda root: True), ("configured_url", lambda root: ""),
                            ("pages", lambda url: [{"url": self.url()}]), ("busiest", lambda tabs: (tabs or [None])[0])):
            patch(live, name, value)
        patch(self.errands, "launch", lambda home, errand_id, message=None, **_: self.launches.append((errand_id, message)) or True)
        patch(self.errands, "open_goal", lambda entry: None)
        patch(self.errands, "prepare_browser", lambda home: True)
        patch(self.errands, "_fetch", lambda *a, **k: (_ for _ in ()).throw(OSError("offline")))
        patch(self.errands, "page_picture", lambda *a, **k: "")
        patch(self.errands, "release_context", lambda *a, **k: True)
        patch(self.errands, "start_sweeper", lambda *a, **k: False)
        patch(self.access, "target", self.target)
        patch(self.access, "page_evaluate", lambda context, code: self.page().evaluate(code))
        patch(self.prices, "https", lambda url: url if str(url).startswith("https://") else (_ for _ in ()).throw(ValueError("https")))
        for name in ("discover", "verify", "present", "resolve", "verify_remaining"):
            original = getattr(self.prices, name)
            patch(self.prices, name, lambda *a, _fn=original, **kw: _fn(*a, **{**kw, "factory": self.probe}))
        if "ledger_unwritable" in self.faults:
            patch(self.purchases, "record", lambda *a, **k: (_ for _ in ()).throw(OSError("disco lleno")))
        if "no_delivery_details" not in self.faults:
            self.ask.save_details(self.home, {"name": "Prueba", "surname": "Simulada", "address": "Calle Falsa 1",
                                              "postcode": "28013", "city": "Madrid", "province": "Madrid",
                                              "phone": "600000000", "email": "prueba@example.com", "country": "ES"})
        # Registered as Hermes does: every hook and tool, in the plugin's own order.
        self.hooks: Dict[str, List[Callable]] = {}
        self.tools: Dict[str, Dict[str, Any]] = {}
        sim = self

        class Ctx:
            def register_hook(self, name, fn):
                sim.hooks.setdefault(name, []).append(fn)

            def register_tool(self, **kw):
                sim.tools[kw["name"]] = kw

            def __getattr__(self, name):
                return lambda *a, **k: None

        p.register(Ctx())
        # The dashboard the iPhone talks to, with the same modules.
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        self.api = load("alice_qa_plugin_api", PLUGIN / "dashboard" / "plugin_api.py")
        patch(self.api, "_hermes_root", lambda: self.home)
        app = FastAPI()
        app.include_router(self.api.router, prefix=self.api.PLUGIN_PREFIX)
        self.client = TestClient(app)
        self.oracle = Oracle(self.home, self.errands, self.purchases, self.flow)
        self.gateway = Gateway(self)
        self.robot = Robot(self)
        self.person = Person(self)
        return self

    def __exit__(self, *exc):
        for page in self.pages:
            page.close()
        self.stack.close()
        for name in ("alice_qa_plugin", "alice_qa_plugin_api"):
            sys.modules.pop(name, None)
        return False

    # ── Browsers ─────────────────────────────────────────────────────────────────

    def probe(self, home):
        """A disposable context for the chat's price checks: fresh shops, no basket."""
        sim = self

        class Probe:
            def __init__(self):
                self.js = shops.JsPage(sim.world.router())
                sim.pages.append(self.js)

            def goto(self, url):
                self.js.goto(sim.prices.https(url))
                if not sim.prices.same_site(self.js.url(), url):
                    raise ValueError("La tienda redirigió a otro origen.")

            def evaluate(self, script):
                return self.js.evaluate(script)

            def sleep(self, seconds):
                pass

            def close(self):
                pass

        return Probe()

    def page(self) -> shops.JsPage:
        """The errand's own tab, in its own context (made on first use, made again after a crash)."""
        if self.errand_js is None:
            self.contexts += 1
            self.ctx = f"ctx-{self.contexts}"
            self.errand_js = shops.JsPage(self.world.router())
            self.pages.append(self.errand_js)
        return self.errand_js

    def url(self) -> str:
        return self.errand_js.url() if self.errand_js else "about:blank"

    def crash_browser(self, errand_id: str) -> None:
        """Chrome closed: the errand's next step finds its context gone and makes another, empty one
        (as errands.context_preamble does), noting it so the plugin can tell the agent."""
        self.errand_js = None
        self.page()
        path = self.errands.context_file(errand_id, self.home)
        path.write_text(json.dumps({"context": self.ctx, "target": "sim-tab", "lost": True}))

    def target(self, entry):
        url = self.url()
        try:
            origin = self.access.origin(url)
        except ValueError:
            origin = url
        command = lambda method, params=None: {"cookies": []} if method == "Storage.getCookies" else {}
        return origin, {"context": self.ctx, "target": "sim-tab", "url": url, "cdp": "sim"}, command

    # ── Running tools through Hermes' hook pipeline ──────────────────────────────

    def call(self, session: str, tool: str, args: Dict[str, Any], effect: Optional[Callable[[], Any]] = None) -> Dict[str, Any]:
        """One tool call exactly as Hermes b889e4e makes it (hermes_cli/plugins.py
        `_get_pre_tool_call_directive_details`, model_tools.py `_apply_transform_tool_result_hook`):
        every pre_tool_call hook sees the ORIGINAL args; «modify» results are shallow-merged; the first
        «block»/«approve» wins. The tool runs with the merged args. post_tool_call runs, then
        transform_tool_result, where every hook sees the original result and the first string wins.
        ``effect`` is what a browser tool does once allowed."""
        self.session = session
        event = f"{session[:12]}:{tool}"
        merged: Optional[Dict[str, Any]] = None
        directive = None
        for hook in self.hooks.get("pre_tool_call", []):
            try:
                verdict = hook(tool_name=tool, args=args, session_id=session)
            except Exception as exc:  # noqa: BLE001 — Hermes isolates it; for us a hook that raises is a bug
                self.oracle.fail("HOOK", event, f"{getattr(hook, '__name__', hook)} lanzó {type(exc).__name__}: {exc}")
                verdict = None
            if not isinstance(verdict, dict):
                continue
            action = verdict.get("action")
            if action == "modify" and isinstance(verdict.get("args"), dict) and verdict["args"]:
                merged = {**(merged if merged is not None else args), **verdict["args"]}
            elif action in ("block", "approve") and directive is None and (action == "approve" or verdict.get("message")):
                directive = verdict
        if directive is not None:
            # «approve» goes to Hermes' approval gate; inside a /v1/runs errand nobody answers it but the
            # engine, so here it is what a person who was not asked would see: not done.
            result = {"blocked": True, "action": directive["action"], "message": directive.get("message", "")}
            self.events.append(event + " ⟂ " + str(directive.get("message", ""))[:80])
            self.oracle.saw_text(json.dumps(result, ensure_ascii=False), event)
            self.oracle.after(event)
            return result
        final = merged if merged is not None else args
        if tool in self.tools:
            raw = self.tools[tool]["handler"](final)
        else:
            raw = json.dumps(effect() if effect else {"ok": True}, ensure_ascii=False, default=str)
        result_text = raw if isinstance(raw, str) else json.dumps(raw, ensure_ascii=False)
        for hook in self.hooks.get("post_tool_call", []):
            try:
                hook(tool_name=tool, args=final, result=result_text, session_id=session, status="ok")
            except Exception as exc:  # noqa: BLE001
                self.oracle.fail("HOOK", event, f"{getattr(hook, '__name__', hook)} lanzó {type(exc).__name__}: {exc}")
        replacements = []
        for hook in self.hooks.get("transform_tool_result", []):
            try:
                changed = hook(tool_name=tool, args=final, result=result_text, session_id=session)
            except Exception as exc:  # noqa: BLE001
                self.oracle.fail("HOOK", event, f"{getattr(hook, '__name__', hook)} lanzó {type(exc).__name__}: {exc}")
                changed = None
            if isinstance(changed, str):
                replacements.append((getattr(hook, "__name__", str(hook)), changed))
        if len(replacements) > 1:
            # Hermes keeps only the first: whatever the others meant to tell the agent is lost.
            self.oracle.fail("HOOK", event, "varios transform_tool_result respondieron y Hermes solo usa el primero: "
                                            + ", ".join(name for name, _ in replacements))
        if replacements:
            result_text = replacements[0][1]
        self.events.append(event)
        self.oracle.saw_text(result_text, event)
        self.oracle.after(event)
        try:
            out = json.loads(result_text)
        except ValueError:
            out = {"text": result_text}
        if isinstance(out, dict) and isinstance(out.get("result"), dict) and "ok" in out:
            out = {**out["result"], "ok": out["ok"], **({"set": out["set"]} if out.get("set") else {})}
        return out if isinstance(out, dict) else {"value": out}

    def chat(self, text: str) -> Optional[Dict[str, Any]]:
        """A message from the person in the chat: the turn hooks run as Hermes runs them."""
        self.session = CHAT
        context = None
        for hook in self.hooks.get("pre_llm_call", []):
            try:
                out = hook(session_id=CHAT, user_message=text)
            except Exception as exc:  # noqa: BLE001
                self.oracle.fail("HOOK", "chat", f"{getattr(hook, '__name__', hook)} lanzó {type(exc).__name__}: {exc}")
                out = None
            if out and out.get("context"):
                context = out["context"]
        self.events.append("chat: " + text[:60])
        self.oracle.after("chat")
        return context

    # ── The errand engine, as `errands.launch` runs it ───────────────────────────

    def drive(self, limit: int = 40) -> None:
        for _ in range(limit):
            if self.launches:
                errand_id, message = self.launches.pop(0)
                pending = (self.errands.get(self.home, errand_id) or {}).get("resume_message")
                if pending:
                    self.errands.update(self.home, errand_id, resume_message=None)
                engine = self.errands.Engine(self.home, errand_id, gateway=self.gateway, judge=self.robot.judge,
                                             sleep=lambda s: None)
                try:
                    engine.run(pending or message)
                except Exception as exc:  # noqa: BLE001 — launch() turns this into «Error interno»
                    self.oracle.fail("P1", "engine", f"el motor lanzó {type(exc).__name__}: {exc}")
                    self.errands.update(self.home, errand_id, status="stuck", reason=f"Error interno: {type(exc).__name__}.")
                self.oracle.after("engine")
                continue
            if not self.person.act():
                return
        self.oracle.fail("P1", "drive", f"el recado no termina tras {limit} rondas de agente y persona")

    def errand(self) -> Optional[Dict[str, Any]]:
        found = [e for e in self.errands.listing(self.home) if e.get("origin_session") == CHAT]
        return found[-1] if found else None


class Robot:
    """A competent agent that follows the `comprar` skill to the letter, and nothing more."""

    def __init__(self, sim: Sim):
        self.sim = sim
        self.paid: Dict[str, bool] = {}
        self.added: Dict[str, str] = {}
        self.carts: Dict[str, str] = {}
        self.checkouts: Dict[str, str] = {}
        self.outcome_written: Dict[str, bool] = {}

    # The chat: search, check, cards (steps 1–6).
    def shop_for(self) -> Optional[str]:
        sim, case = self.sim, self.sim.case
        sim.chat(f"Cómprame {case['query']} en {case['host']}")
        found = sim.call(CHAT, "purchase_discover", {"shop": case["host"], "query": case["query"]})
        if not found.get("ok") or not found.get("candidates"):
            sim.oracle.fail("FLOW", "discover", "la búsqueda no encontró el producto: " + json.dumps(found, ensure_ascii=False)[:300])
            return None
        quote = sim.call(CHAT, "purchase_verify", {"search_id": found["id"], "candidate_id": found["candidates"][0]["id"],
                                                    "currency": "EUR", "variant": case["variant"]})
        if not quote.get("ok") or not quote.get("id"):
            sim.oracle.fail("FLOW", "verify", "la comprobación falló: " + json.dumps(quote, ensure_ascii=False)[:300])
            return None
        sim.oracle.cards_shown(CHAT, "verify")
        return quote.get("set")

    def judge(self, session_id: str, reply: str) -> Dict[str, Any]:
        entry = self.sim.errands.of_session(self.sim.home, session_id) or {}
        if self.sim.fault("judge_down_after_approval", once=False) and (entry.get("checkout") or {}).get("status") == "approved":
            raise RuntimeError("el juez no responde")
        if str(reply).startswith("HECHO"):
            return {"status": "done"}
        return {"should_continue": True, "continuation_prompt": self.sim.errands.CONTINUATION}

    # The errand (steps 7–12).
    def errand_turn(self, session: str, text: str) -> str:
        sim = self.sim
        sim.person.heard(session, text)
        entry = sim.errands.of_session(sim.home, session)
        offer = entry.get("offer") or {}
        receipt = entry.get("receipt") or {}
        if receipt.get("outcome") in ("paid", "declined", "not_charged"):
            return "HECHO: ya registrado."
        if self.paid.get(entry["id"]):
            return self.write_outcome(entry, session) if not sim.fault("outcome_never_written", once=False) else "Pagado, creo."
        checkout = entry.get("checkout") or {}
        if checkout.get("status") == "approved":
            if sim.fault("chrome_crash_before_paying"):
                # Chrome closed under the agent. A careless model goes straight back to the checkout it
                # remembers and pays; the plugin must stop it (the basket there is new and empty).
                sim.crash_browser(entry["id"])
                self.added.pop(entry["id"], None)
                if self.checkouts.get(entry["id"]):
                    self.go(session, self.checkouts[entry["id"]])
            return self.pay(entry, session)
        return self.prepare(entry, session, offer)

    def go(self, session: str, url: str) -> Dict[str, Any]:
        return self.sim.call(session, "browser_exec", {"code": f"# Abrir {url}\ngoto({url!r})"},
                             effect=lambda: self.sim.page().goto(url) or {"ok": True, "url": url})

    def click(self, session: str, label: str, pays: bool = False) -> Dict[str, Any]:
        sim = self.sim

        def effect():
            page = sim.page()
            exists = page.evaluate("((label)=>!!Array.from(document.querySelectorAll('a,button,input[type=submit]'))"
                                   ".find(e=>(e.innerText||e.value||'').trim().toLowerCase().includes(label.toLowerCase())))("
                                   + json.dumps(label) + ")")
            if pays and exists:
                # Only a button that is there pays: the oracle judges the press as it happens.
                entry = sim.errands.of_session(sim.home, session)
                total = (sim.engine.errand_total(page.evaluate) or {}).get("text")
                sim.oracle.before_pay(entry, total, sim.ctx, f"{session[:12]}:pagar")
            found = page.evaluate("((label)=>{const e=Array.from(document.querySelectorAll('a,button,input[type=submit]'))"
                                  ".find(e=>(e.innerText||e.value||'').trim().toLowerCase().includes(label.toLowerCase()));"
                                  "if(!e)return null;if(e.tagName==='A')return {href:e.href};e.click();return {clicked:true}})("
                                  + json.dumps(label) + ")")
            if found and found.get("href"):
                page.goto(found["href"])
            return {"ok": bool(found), "url": page.url()}

        return sim.call(session, "browser_click", {"text": label}, effect=effect)

    def prepare(self, entry: Dict[str, Any], session: str, offer: Dict[str, Any]) -> str:
        sim, engine = self.sim, self.sim.engine
        if self.added.get(entry["id"]) != sim.ctx or not sim.ctx:
            self.go(session, offer["url"])
            page = engine.Page(sim.page().evaluate, sim.page().goto, sim.page().url, sleep=lambda s: None)
            sim.call(session, "browser_exec", {"code": f"# Elegir {offer.get('variant')}\nselect_option(...)"},
                     effect=lambda: engine.select_variant(page, offer.get("variant") or ""))
            if int(offer.get("qty") or 1) > 1:
                sim.call(session, "browser_exec", {"code": "# Unidades\nset_value('qty', ...)"},
                         effect=lambda: engine.set_units(page, int(offer.get("qty") or 1)))
            label = page.evaluate("(Array.from(document.querySelectorAll('button')).find(b=>/añadir|anadir|add/i.test(b.innerText))||{}).innerText||''")
            added = self.click(session, label or "Añadir")
            if added.get("blocked"):
                return "BLOQUEADO: no me deja añadir a la cesta: " + added.get("message", "")[:120]
            self.added[entry["id"]] = sim.ctx
        page = engine.Page(sim.page().evaluate, sim.page().goto, sim.page().url, sleep=lambda s: None)
        # Where the cart is, as a model remembers it from the product page (a checkout page often
        # has no link back to it).
        link = engine.cart_link(page) or self.carts.get(entry["id"], "")
        if link:
            self.carts[entry["id"]] = link
            self.go(session, link)
        checked = sim.call(session, "purchase_check_cart", {})
        if not checked.get("ok"):
            if checked.get("price_changed"):
                return f"BLOQUEADO: precio {checked.get('price')} — la cesta cobra otro precio"
            error = str(checked.get("error") or "")
            if re.search(r"agotad|no contiene|no est[aá] disponible|sin stock", error, re.I):
                return "BLOQUEADO: " + error[:200]
            return "No he podido comprobar la cesta: " + error[:200]
        step = sim.page().evaluate("(Array.from(document.querySelectorAll('a,button')).find(b=>/finalizar|tramitar|checkout/i.test(b.innerText))||{}).innerText||''")
        self.click(session, step or "Finalizar compra")
        self.checkouts[entry["id"]] = sim.url()
        if sim.fault("agent_pays_without_approval"):
            # A model that skips the approval on the checkout page: the gates must refuse it.
            label = sim.page().evaluate("(Array.from(document.querySelectorAll('button')).find(b=>/pagar|realizar el pedido|pay/i.test(b.innerText))||{}).innerText||''")
            self.click(session, label or "Pagar ahora", pays=True)
        request = {"merchant": sim.case["merchant"], "site": sim.case["host"], "items": [{"name": offer.get("title")}],
                   "payment_method": "card", "card_label": CARD_LABEL}
        out = sim.call(session, "checkout_request", request)
        if out.get("ok"):
            return "Esperando tu aprobación del total."
        return "No he podido preparar el resumen: " + str(out.get("error") or out.get("message") or "")[:200]

    def pay(self, entry: Dict[str, Any], session: str) -> str:
        sim = self.sim
        if sim.fault("total_changed_before_paying"):
            sim.page().evaluate("(()=>{for(const e of document.querySelectorAll('b,strong')){if(/€/.test(e.textContent)){"
                                "const v=Number(e.textContent.replace(/[^0-9,]/g,'').replace(',','.'))+1;"
                                "e.textContent=v.toFixed(2).replace('.',',')+' €';}}})()")
        fill = sim.call(session, "browser_vault_fill", {"handle": "card-1"},
                        effect=lambda: {"success": True, "kind": "payment", "origin": sim.access.origin(sim.url())})
        if fill.get("blocked"):
            return self.after_block(entry, session, fill)
        label = sim.page().evaluate("(Array.from(document.querySelectorAll('button')).find(b=>/pagar|realizar el pedido|pay/i.test(b.innerText))||{}).innerText||''")
        paid = self.click(session, label or "Pagar ahora", pays=True)
        if paid.get("blocked"):
            return self.after_block(entry, session, paid)
        self.paid[entry["id"]] = True
        if sim.fault("pay_twice"):
            again = self.click(session, label or "Pagar ahora", pays=True)
            if not again.get("blocked"):
                sim.events.append("pay_twice: segundo clic permitido")
        if sim.fault("outcome_never_written", once=False):
            return "Pagado, creo."
        return self.write_outcome(entry, session)

    def after_block(self, entry, session, verdict) -> str:
        message = verdict.get("message", "")
        if "checkout_request" in message:
            # As the gate says: the total changed or the evidence is stale; show the new one.
            sim = self.sim
            return self.prepare(sim.errands.get(sim.home, entry["id"]), session, entry.get("offer") or {})
        return "No pago: " + message[:160]

    def write_outcome(self, entry, session) -> str:
        sim = self.sim
        outcome = "declined" if sim.fault("declined") else "paid"
        total = (sim.engine.errand_total(sim.page().evaluate) or {}).get("text") or (entry.get("checkout") or {}).get("total", "")
        out = sim.call(session, "purchase_outcome", {"site": sim.case["host"], "outcome": outcome,
                                                     "order": "SIM-" + entry["id"][:6] if outcome == "paid" else "",
                                                     "total": total})
        if not out.get("ok"):
            sim.oracle.fail("I5", "outcome", "purchase_outcome rechazado tras pagar: " + json.dumps(out, ensure_ascii=False)[:200])
        self.outcome_written[entry["id"]] = True
        return "HECHO: pedido registrado (" + outcome + ")."


class Person:
    """Answers what the errand asks, through the routes the iPhone uses."""

    def __init__(self, sim: Sim):
        self.sim = sim
        self.expect: Dict[str, str] = {}
        self.accepted_price = False

    def heard(self, session: str, text: str) -> None:
        """I4: the next turn of an errand the person answered carries that answer."""
        sim = self.sim
        sim.oracle.saw_text(text, "turn")
        wanted = self.expect.pop(session, None)
        if wanted and wanted not in str(text):
            sim.oracle.fail("I4", "turn", f"la respuesta de la persona ({wanted}) no llegó al recado; llegó: {str(text)[:120]!r}")

    def post(self, entry, path, body):
        url = f"{self.sim.api.PLUGIN_PREFIX}/errands/{entry['id']}{path}"
        response = self.sim.client.post(url, json=body)
        self.sim.events.append(f"persona {path} → {response.status_code}")
        self.sim.oracle.after("persona " + path)
        return response

    def cards(self) -> Optional[Dict[str, Any]]:
        """What the app draws under the reply, read as the iPhone reads it (GET /purchase/sets, then
        /purchase/options/{key}): the recommended card, or nothing when the app would show none (I6)."""
        sim = self.sim
        prefix = sim.api.PLUGIN_PREFIX
        listed = sim.client.get(f"{prefix}/purchase/sets", params={"session": CHAT, "since": 0})
        sets = listed.json().get("sets") if listed.status_code == 200 else None
        if not sets:
            sim.oracle.fail("I6", "app", f"la app no recibe tarjetas (GET /purchase/sets → {listed.status_code})")
            return None
        key = sets[-1]["key"]
        shown = sim.client.get(f"{prefix}/purchase/options/{key}", params={"session": CHAT})
        options = shown.json().get("options") if shown.status_code == 200 else None
        if not options:
            sim.oracle.fail("I6", "app", f"la app no puede abrir las tarjetas {key} (→ {shown.status_code})")
            return None
        if len([o for o in options if o.get("recommended")]) != 1:
            sim.oracle.fail("I6", "app", "las tarjetas no llevan exactamente una recomendada")
        if any(not str(o.get("id", "")).startswith(key + "-") for o in options):
            sim.oracle.fail("I6", "app", "un id de tarjeta no lleva la clave de su conjunto: el toque no la encontraría")
        sim.events.append(f"app: {len(options)} tarjeta(s) {key}")
        return next((o for o in options if o.get("recommended")), options[0])

    def act(self) -> bool:
        sim = self.sim
        entry = sim.errand()
        if entry is None:
            return False
        status, checkout = entry.get("status"), entry.get("checkout") or {}
        if status == "needs_approval" and checkout.get("status") == "pending":
            if sim.fault("denied"):
                self.post(entry, "/checkout", {"decision": "deny", "checkout_id": checkout["id"]})
                return True
            first = self.post(entry, "/checkout", {"decision": "allow", "checkout_id": checkout["id"], "card_label": CARD_LABEL})
            if first.status_code == 200:
                self.expect[entry["session_id"]] = sim.errands.APPROVED_PREFIX
            if sim.fault("double_approval"):
                second = self.post(entry, "/checkout", {"decision": "allow", "checkout_id": checkout["id"], "card_label": CARD_LABEL})
                if second.status_code != 200:
                    sim.oracle.fail("P1", "persona", f"un segundo «Permitir» idéntico devolvió {second.status_code}")
            return first.status_code == 200
        if status == "needs_input":
            items = (entry.get("questions") or {}).get("items") or []
            details = {"name": "Prueba", "surname": "Simulada", "address": "Calle Falsa 1", "postcode": "28013",
                       "city": "Madrid", "province": "Madrid", "phone": "600000000", "email": "prueba@example.com"}
            answers = {q["id"]: details.get(q["id"]) or (q.get("choices") or ["sí"])[0] for q in items}
            response = self.post(entry, "/answer", {"answers": answers})
            if response.status_code == 200:
                self.expect[entry["session_id"]] = "[respuesta:"
            return response.status_code == 200
        if status == "needs_card":
            sim.cards.items["card-1"] = Card(id="card-1", kind="payment", origin="https://" + sim.case["host"], label=CARD_LABEL)
            response = self.post(entry, "/card", {"label": CARD_LABEL})
            if response.status_code == 200:
                self.expect[entry["session_id"]] = "[tarjeta lista]"
            return response.status_code == 200
        if status == "stuck":
            blocked = entry.get("blocked") or {}
            if blocked.get("kind") == "price" and not self.accepted_price:
                self.accepted_price = True
                response = self.post(entry, "/continue", {"accept_price": True})
                if response.status_code == 200:
                    self.expect[entry["session_id"]] = "[precio aceptado]"
                return response.status_code == 200
        return False


def run(shop: str = "tienda-tres.example", faults: Sequence[str] = (), seed: int = 0,
        mutate: Optional[Callable[[Sim], None]] = None) -> Dict[str, Any]:
    """One scenario: the person asks, taps the recommended card, and answers whatever the errand asks.
    ``mutate`` changes the plugin before it runs (used by tests/test_qa.py to put an old bug back and
    prove the oracle sees it); it patches through ``sim.stack`` so nothing outlives the run."""
    started = time.monotonic()
    with Sim(shop, faults, seed) as sim:
        if mutate is not None:
            mutate(sim)
        try:
            sim.robot.shop_for()
            option = sim.person.cards()
            if option:
                qty = int(sim.case.get("qty") or 1)
                if sim.fault("price_changed"):
                    sim.world.price_delta = 500
                if sim.fault("sold_out_after_choice"):
                    sim.world.sold_out = True
                sim.chat(f"[elección:{option['id']}] {option['title']} · {option['price']}" + (f" [cantidad:{qty}]" if qty > 1 else ""))
                sim.drive()
        except Exception as exc:  # noqa: BLE001 — a crash anywhere is a finding, never a silent pass
            sim.oracle.fail("SIM", "run", "".join(traceback.format_exception(exc))[-800:])
        entry = sim.errand()
        status = (entry or {}).get("status")
        outcome = ((entry or {}).get("receipt") or {}).get("outcome")
        want_status, want_outcome = EXPECTED.get(tuple(sorted(faults)), (None, None))
        if want_status and status != want_status:
            sim.oracle.fail("FLOW", "fin", f"terminó en «{status}» y se esperaba «{want_status}» "
                                           f"(motivo: {(entry or {}).get('reason')!r})")
        if want_outcome and outcome != want_outcome:
            sim.oracle.fail("FLOW", "fin", f"resultado «{outcome}» y se esperaba «{want_outcome}»")
        return {"shop": shop, "faults": list(faults), "seed": seed, "status": status, "outcome": outcome,
                "pays": sum(sim.oracle.pays.values()), "findings": sim.oracle.findings, "events": sim.events[-80:],
                "seconds": round(time.monotonic() - started, 1),
                "snapshots": [sim.errands.public(e) for e in sim.errands.listing(sim.home)],
                "states": sim.oracle.states}


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--shop", default="tienda-tres.example")
    parser.add_argument("--fault", action="append", default=[])
    args = parser.parse_args()
    report = run(args.shop, args.fault)
    print(json.dumps({k: v for k, v in report.items() if k != "snapshots"}, ensure_ascii=False, indent=1))
