"""Loopback-only HTTPS merchant. All purchases are SYNTHETIC test events.

No real payments, card numbers, user accounts, merchant network or browser.
"""

from __future__ import annotations

import json
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class FictionalStore:
    product = {"sku": "FAKE-ALICE-1", "name": "Fictional ergonomic keyboard",
               "description": "Quiet keys, compact ISO layout, fictional merchant stock.",
               "unit_minor": 2499, "currency": "EUR"}

    def __init__(self, *, secret: str):
        self.secret = secret
        self._lock = threading.RLock()
        self.carts: dict[str, dict] = {}
        self.orders: dict[str, dict] = {}
        self.submit_attempts = 0
        self.price_override: int | None = None
        self.fail_next_submit = False
        self.fail_next_quote = False
        self.certified_adapter = True

    def quote(self, cart_id: str, recipient: str) -> dict:
        with self._lock:
            entry = self.carts.get(cart_id)
            if entry is None or not isinstance(recipient, str):
                raise ValueError("cart missing")
            price = self.price_override if self.price_override is not None else self.product["unit_minor"]
            return {"sku": entry["sku"], "quantity": entry["quantity"], "recipient": recipient,
                    "amount_minor": price * entry["quantity"], "currency": "EUR"}


def make_handler(store: FictionalStore):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            # No request tokens, card numbers or test user context in logs.
            return

        def _send(self, status, data):
            payload = json.dumps(data).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _auth(self):
            if self.headers.get("Authorization") != "Bearer " + store.secret:
                self._send(403, {"error": "denied"})
                return False
            return True

        def do_GET(self):
            if not self._auth():
                return
            url = urlsplit(self.path)
            if url.path == "/search":
                q = parse_qs(url.query).get("q", [""])[0].lower()
                self._send(200, {"products": [{"sku": store.product["sku"], "name": store.product["name"]}]
                                 if any(word in q for word in ("keyboard", "teclado", "alice")) else []})
            elif url.path == "/product/" + store.product["sku"]:
                self._send(200, store.product)
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._auth():
                return
            try:
                size = int(self.headers.get("Content-Length", "-1"))
                if size < 2 or size > 8192:
                    raise ValueError("invalid request size")
                body = json.loads(self.rfile.read(size))
                if not isinstance(body, dict):
                    raise ValueError("invalid input")
                if self.path == "/cart":
                    if (body.get("sku") != store.product["sku"]
                            or type(body.get("quantity")) is not int or not 1 <= body["quantity"] <= 5
                            or not isinstance(body.get("cart_id"), str) or len(body["cart_id"]) > 100):
                        raise ValueError("bad cart")
                    with store._lock:
                        store.carts[body["cart_id"]] = {"sku": body["sku"], "quantity": body["quantity"]}
                    self._send(200, {"sku": body["sku"], "quantity": body["quantity"]})
                elif self.path == "/quote":
                    if store.fail_next_quote:
                        store.fail_next_quote = False
                        self._send(503, {"error": "temporary unavailable"})
                    else:
                        self._send(200, store.quote(body["cart_id"], body["recipient"]))
                elif self.path == "/commit":
                    with store._lock:
                        store.submit_attempts += 1
                        if store.fail_next_submit:
                            store.fail_next_submit = False
                            self._send(503, {"error": "effect uncertain"})
                            return
                        snap = body["snapshot"]
                        expected = store.quote(body["cart_id"], body["recipient"])
                        if (snap.get("sku") != expected["sku"] or snap.get("quantity") != expected["quantity"]
                                or snap.get("recipient") != expected["recipient"]
                                or snap.get("amount_minor") != expected["amount_minor"]
                                or snap.get("currency") != expected["currency"]
                                or body.get("idempotency_key") != snap.get("checkout_id")
                                or not store.certified_adapter):
                            raise ValueError("unverified checkout")
                        key = body["idempotency_key"]
                        order = store.orders.setdefault(key, {
                            "order_id": "FAKE-ORDER-" + str(len(store.orders) + 1),
                            "checkout_id": key, "amount_minor": expected["amount_minor"],
                            "currency": expected["currency"],
                        })
                    self._send(200, order)
                else:
                    self._send(404, {"error": "not found"})
            except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                self._send(422, {"error": "invalid synthetic request"})

    return Handler


class FixtureHTTPS:
    def __init__(self, store: FictionalStore, cert_file: str, key_file: str):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(store))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=cert_file, keyfile=key_file)
        self.server.socket = ctx.wrap_socket(self.server.socket, server_side=True)
        self.url = f"https://localhost:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
