"""The shop engine and the money gates in a real Chrome, on three fictional shops and a bank page.

Every request the browser makes is intercepted (CDP Fetch) and answered by the fixture shops in
hermes-plugin/tests/fixtures/shops.py; anything else is refused. Chrome runs headless on a random
loopback port, never 9222, with a throwaway profile. No real shop, account, card or payment.

    python scripts/verify-shops.py            # needs `websockets` and a Chrome/Chromium binary
    CHROME=/path/to/chrome python scripts/verify-shops.py
"""
from __future__ import annotations

import base64
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "hermes-plugin" / "tests" / "fixtures"))
import shops  # noqa: E402


def load(name):
    key = "alice_" + name
    if key not in sys.modules:
        spec = importlib.util.spec_from_file_location(key, ROOT / "hermes-plugin" / (name + ".py"))
        sys.modules[key] = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sys.modules[key])
    return sys.modules[key]


def chrome_binary() -> str:
    for candidate in (os.environ.get("CHROME"), "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
                      shutil.which("google-chrome"), shutil.which("google-chrome-stable"), shutil.which("chromium"),
                      shutil.which("chromium-browser"),
                      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"):
        if candidate and Path(candidate).exists():
            return candidate
    raise SystemExit("No Chrome/Chromium found; set CHROME=/path/to/chrome")


class Bank(shops.Shop):
    """A bank's card page (on a real gateway host, so the gates treat it as one)."""
    host = "sis.redsys.es"

    def request(self, method, url, body=""):
        return shops.html("<h1>Pago seguro</h1><form><input name=cardNumber autocomplete=cc-number>"
                          "<input name=cvv autocomplete=cc-csc><button type=button onclick='window.paid=true'>Pagar</button></form>")


class Elsewhere(shops.Shop):
    host = "otro-sitio.example"

    def request(self, method, url, body=""):
        return shops.html("<h1>Una página cualquiera</h1><p>Total 193,89 €</p>")


def main() -> None:
    prices = load("purchase_prices")
    engine, errands = load("shop_engine"), load("errands")
    try:
        from tools.url_safety import is_safe_url  # noqa: F401 — Hermes present: its validator stays
    except Exception:  # noqa: BLE001 — without Hermes, only the scheme is checked (all traffic is fixture)
        prices.https = lambda url: url if urlsplit(url).scheme == "https" else (_ for _ in ()).throw(ValueError("https"))
    generic, shopify, woo = shops.Generic(), shops.ShopifyLike(), shops.WooLike()
    router = shops.Router(generic, shopify, woo, Bank(), Elsewhere())
    with tempfile.TemporaryDirectory(prefix="alice-shops-") as folder:
        home = Path(folder)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        assert port != 9222
        endpoint = f"http://127.0.0.1:{port}"
        chrome = subprocess.Popen([chrome_binary(), "--headless=new", f"--remote-debugging-port={port}",
                                   "--remote-debugging-address=127.0.0.1", f"--user-data-dir={home / 'profile'}",
                                   "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--no-sandbox",
                                   "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                try:
                    urllib.request.urlopen(endpoint + "/json/version", timeout=1).close()
                    break
                except OSError:
                    time.sleep(0.1)

            class FixtureProbe(prices.Probe):
                def __init__(self, root):
                    for shop in router.shops.values():
                        shop.cart, shop.coupon = [], ""
                    super().__init__(root, endpoint)
                    self.call("Fetch.enable", {"patterns": [{"urlPattern": "*", "requestStage": "Request"}]}, page=True)

                def sleep(self, seconds):
                    time.sleep(min(seconds, 0.4))

                def call(self, method, params=None, page=False):
                    self.sequence += 1
                    current = self.sequence
                    message = {"id": current, "method": method, "params": params or {}}
                    if page:
                        message["sessionId"] = self.session
                    self.socket.send(json.dumps(message))
                    while True:
                        reply = json.loads(self.socket.recv(timeout=20))
                        if reply.get("method") == "Fetch.requestPaused":
                            request = reply["params"]
                            req = request["request"]
                            status, ctype, text, headers = router.request(req["method"], req["url"], req.get("postData") or "")
                            self.sequence += 1
                            if status == 502:
                                answer = {"id": self.sequence, "sessionId": self.session, "method": "Fetch.failRequest",
                                          "params": {"requestId": request["requestId"], "errorReason": "BlockedByClient"}}
                            else:
                                answer = {"id": self.sequence, "sessionId": self.session, "method": "Fetch.fulfillRequest",
                                          "params": {"requestId": request["requestId"], "responseCode": status,
                                                     "responseHeaders": [{"name": "Content-Type", "value": ctype}]
                                                     + [{"name": k, "value": v} for k, v in headers.items()],
                                                     "body": base64.b64encode(text.encode()).decode()}}
                            self.socket.send(json.dumps(answer))
                        if reply.get("id") == current:
                            if reply.get("error"):
                                raise ValueError("CDP: " + json.dumps(reply["error"]))
                            return reply.get("result") or {}

            # 1. Chat: shop + query in, a checked quote out, on three platforms.
            for shop, query, variant, expected in (("tienda-uno.example", "creatina creapure", "500 g", "34,99 €"),
                                                   ("tienda-dos.example", "proteina whey", "Vainilla", "32,90 €"),
                                                   ("tienda-tres.example", "zapatillas trail", "43", "94,95 €")):
                search = prices.discover(home, "chat", {"shop": shop, "query": query}, factory=FixtureProbe)
                quote = prices.verify(home, "chat", {"search_id": search["id"], "candidate_id": search["candidates"][0]["id"],
                                                     "currency": "EUR", "variant": variant}, factory=FixtureProbe)
                assert (quote["price"], quote["basis"]) == (expected, "cart"), quote
                print(f"PASS: {shop} — {quote['title']} · {quote['variant']} · {quote['price']} from the {quote['basis']}", flush=True)

            # 2. Errand: its own basket and total read without selectors, then the money gates.
            browser = FixtureProbe(home)
            try:
                generic.cart = [{"slug": "zapatillas-trail-x", "size": "43", "qty": 2}]
                offer = {"option_id": "x-1", "title": "Zapatillas Trail X", "variant": "Talla 43", "qty": 2, "price": "94,95 €",
                         "currency": "EUR", "url": "https://tienda-tres.example/p/zapatillas-trail-x", "quote_ref": "pq-x"}
                entry = errands.create(home, "Comprar zapatillas", offer=offer)
                context = {"context": browser.context, "target": browser.target, "cdp": endpoint}
                page_origin = lambda: "https://" + (urlsplit(browser.evaluate("location.href")).hostname or "")
                inspect = lambda e: (page_origin(), context, lambda method, params: browser.call(method, params))
                evaluate = lambda ctx, code: browser.evaluate(code)
                browser.goto("https://tienda-tres.example/cesta")
                checked = prices.check_cart(home, entry["id"], {}, inspect=inspect, evaluate=evaluate)
                assert checked["ok"] and checked["price"] == "94,95 €", checked
                browser.goto("https://tienda-tres.example/pedido")
                total = prices.checkout_amount(errands.get(home, entry["id"]), "", inspect=inspect, evaluate=evaluate)
                assert total == "193,89 €", total
                result = errands.request_checkout(home, entry["id"], {"merchant": "Tienda Tres", "site": "tienda-tres.example",
                                                                      "items": [{"name": "Zapatillas Trail X"}], "total": total},
                                                  fetch=lambda *a: (_ for _ in ()).throw(OSError("offline")))
                assert result["status"] == "needs_approval", result
                pending = errands.get(home, entry["id"])["checkout"]
                errands.update(home, entry["id"], checkout_evidence={"checkout_id": pending["id"], "selector": "", "engine": True})
                gateways = {"sis.redsys.es"}
                assert not prices.payment_ready(home, errands.get(home, entry["id"]), inspect=inspect, evaluate=evaluate, gateways=gateways)
                errands.decide_checkout(home, entry["id"], True)
                assert prices.payment_ready(home, errands.get(home, entry["id"]), inspect=inspect, evaluate=evaluate, gateways=gateways)
                browser.evaluate("document.querySelector('.grand b').textContent='199,89 €'")
                assert not prices.payment_ready(home, errands.get(home, entry["id"]), inspect=inspect, evaluate=evaluate, gateways=gateways)
                print("PASS: errand basket and total read with no selector; unapproved or changed totals are refused", flush=True)
                browser.goto("https://sis.redsys.es/sis/realizarPago")
                assert prices.payment_ready(home, errands.get(home, entry["id"]), inspect=inspect, evaluate=evaluate, gateways=gateways)
                browser.goto("https://otro-sitio.example/")
                assert not prices.payment_ready(home, errands.get(home, entry["id"]), inspect=inspect, evaluate=evaluate, gateways=gateways)
                assert not browser.evaluate("window.paid === true")
                print("PASS: the bank's card page is where the approved order is paid; any other site is refused; nothing was paid", flush=True)
            finally:
                browser.close()
        finally:
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                chrome.kill()


if __name__ == "__main__":
    main()
