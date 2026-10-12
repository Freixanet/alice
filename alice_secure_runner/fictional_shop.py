"""Loopback-only HTTPS merchant. All purchases are SYNTHETIC test events.

No real payments, card numbers, user accounts, merchant network or browser.
"""

from __future__ import annotations

import json
import html
import secrets
import sqlite3
import time
import ssl
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class FictionalStore:
    merchant_id = "alice-fictional-merchant-v1"
    product = {"sku": "FAKE-ALICE-1", "name": "Fictional ergonomic keyboard",
               "description": "Quiet keys, compact ISO layout, fictional merchant stock.",
               "unit_minor": 2499, "currency": "EUR",
               "variants": ["standard", "graphite"]}
    variant_upcharge_minor = {"standard": 0, "graphite": 500}

    def __init__(self, *, secret: str):
        self.secret = secret
        # Separate least-privilege browser read token: it can NEVER write cart,
        # quote or commit, even if hostile page JS evades Playwright routes.
        self.browser_read_secret = secrets.token_urlsafe(40)
        self._lock = threading.RLock()
        self.carts: dict[str, dict] = {}
        self.orders: dict[str, dict] = {}
        self.submit_attempts = 0
        self.price_override: int | None = None
        self.tax_minor_override = 0
        self.shipping_minor_override = 0
        self.discount_minor_override = 0
        self.fail_next_submit = False
        self.fail_next_quote = False
        self.certified_adapter = True
        self.redirect_browser_to: str | None = None
        self.redirect_hits = 0
        self.redirect_auth_header_seen = False
        self.commit_delay_seconds = 0  # H01 synthetic crash-window laboratory only.

    def quote(self, cart_id: str, recipient: str) -> dict:
        with self._lock:
            entry = self.carts.get(cart_id)
            if entry is None or not isinstance(recipient, str):
                raise ValueError("cart missing")
            variant = entry.get("variant", "standard")
            price = (self.price_override if self.price_override is not None
                     else self.product["unit_minor"] + self.variant_upcharge_minor[variant])
            subtotal = price * entry["quantity"]
            tax = self.tax_minor_override
            shipping = self.shipping_minor_override
            discount = self.discount_minor_override
            return {"sku": entry["sku"], "variant": variant,
                    "quantity": entry["quantity"], "recipient": recipient,
                    "merchant_id": self.merchant_id, "subtotal_minor": subtotal,
                    "tax_minor": tax, "shipping_minor": shipping, "discount_minor": discount,
                    "amount_minor": subtotal + tax + shipping - discount, "currency": "EUR"}

    def put_cart(self, cart_id: str, sku: str, quantity: int, variant: str = "standard") -> None:
        with self._lock:
            self.carts[cart_id] = {"sku": sku, "variant": variant, "quantity": quantity}

    def record_order(self, key: str, expected: dict) -> dict:
        with self._lock:
            previous = self.orders.get(key)
            if previous is not None:
                # An idempotency key must never be repurposed for a different
                # amount, recipient or cart after a network failure.
                if any(previous[name] != expected[name] for name in
                       ("sku", "variant", "quantity", "recipient", "merchant_id",
                        "subtotal_minor", "tax_minor", "shipping_minor",
                        "discount_minor", "amount_minor", "currency")):
                    raise ValueError("idempotency key changed checkout")
                return previous.copy()
            order = {"order_id": "FAKE-ORDER-" + str(len(self.orders) + 1),
                     "checkout_id": key,
                     **{name: expected[name] for name in
                        ("sku", "variant", "quantity", "recipient", "merchant_id",
                         "subtotal_minor", "tax_minor", "shipping_minor",
                         "discount_minor", "amount_minor", "currency")}}
            self.orders[key] = order
            return order.copy()

    def receipt(self, key: str) -> dict | None:
        with self._lock:
            result = self.orders.get(key)
            return result.copy() if result else None


class PersistentFictionalStore(FictionalStore):
    """Independently durable fictional merchant; NOT a payment provider.

    This store can run in its own process/container with a SQLite volume that
    outlives deletion and recreation of the Alice Secure Runner process.
    """
    def __init__(self, *, secret: str, ledger_path: str | Path,
                 browser_read_secret: str):
        super().__init__(secret=secret)
        self.browser_read_secret = browser_read_secret
        self._db = sqlite3.connect(str(ledger_path), check_same_thread=False,
                                   isolation_level=None, timeout=5)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("CREATE TABLE IF NOT EXISTS carts "
                         "(cart_id TEXT PRIMARY KEY, sku TEXT NOT NULL, quantity INTEGER NOT NULL,"
                         " variant TEXT NOT NULL DEFAULT 'standard')")
        if "variant" not in {row[1] for row in self._db.execute("PRAGMA table_info(carts)") }:
            self._db.execute("ALTER TABLE carts ADD COLUMN variant TEXT NOT NULL DEFAULT 'standard'")
        self._db.execute("CREATE TABLE IF NOT EXISTS orders "
                         "(checkout_id TEXT PRIMARY KEY, receipt_json TEXT NOT NULL)")
        for cart_id, sku, qty, variant in self._db.execute("SELECT cart_id,sku,quantity,variant FROM carts"):
            self.carts[cart_id] = {"sku": sku, "quantity": qty, "variant": variant}
        for key, raw in self._db.execute("SELECT checkout_id,receipt_json FROM orders"):
            self.orders[key] = json.loads(raw)

    def put_cart(self, cart_id: str, sku: str, quantity: int, variant: str = "standard") -> None:
        with self._lock:
            self._db.execute("INSERT INTO carts(cart_id,sku,quantity,variant) VALUES(?,?,?,?) "
                             "ON CONFLICT(cart_id) DO UPDATE SET sku=excluded.sku,"
                             "quantity=excluded.quantity,variant=excluded.variant",
                             (cart_id, sku, quantity, variant))
            super().put_cart(cart_id, sku, quantity, variant)

    def quote(self, cart_id: str, recipient: str) -> dict:
        with self._lock:
            row = self._db.execute(
                "SELECT sku,quantity,variant FROM carts WHERE cart_id=?",
                (cart_id,)).fetchone()
            if row is None:
                raise ValueError("cart missing from durable merchant")
            self.carts[cart_id] = {
                "sku": row[0], "quantity": row[1], "variant": row[2]}
            return super().quote(cart_id, recipient)

    def record_order(self, key: str, expected: dict) -> dict:
        with self._lock:
            # BEGIN IMMEDIATE serializes separate merchant processes, not
            # merely threads sharing an in-memory dict. A restart or second
            # process must read the authoritative receipt before responding.
            fields = ("sku", "variant", "quantity", "recipient", "merchant_id",
                      "subtotal_minor", "tax_minor", "shipping_minor",
                      "discount_minor", "amount_minor", "currency")
            self._db.execute("BEGIN IMMEDIATE")
            try:
                prior = self._db.execute(
                    "SELECT receipt_json FROM orders WHERE checkout_id=?",
                    (key,)).fetchone()
                if prior is not None:
                    receipt = json.loads(prior[0])
                    if any(receipt.get(name) != expected.get(name) for name in fields):
                        raise ValueError("idempotency key changed checkout")
                else:
                    receipt = {
                        "order_id": "FAKE-ORDER-" + secrets.token_hex(16),
                        "checkout_id": key,
                        **{name: expected[name] for name in fields}}
                    self._db.execute(
                        "INSERT INTO orders(checkout_id,receipt_json) VALUES(?,?)",
                        (key, json.dumps(receipt, sort_keys=True)))
                self._db.execute("COMMIT")
            except BaseException:
                try:
                    self._db.execute("ROLLBACK")
                except sqlite3.Error:
                    # A failed COMMIT can leave the transaction outcome
                    # uncertain. Never fabricate a merchant receipt here.
                    pass
                raise
            self.orders[key] = receipt.copy()
            return receipt.copy()

    def receipt(self, key: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT receipt_json FROM orders WHERE checkout_id=?",
                (key,)).fetchone()
            if row is None:
                return None
            value = json.loads(row[0])
            self.orders[key] = value.copy()
            return value

    def close(self) -> None:
        self._db.close()


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

        def _page(self, status, markup):
            payload = markup.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Set-Cookie", "fixture_session=not-a-real-secret; HttpOnly; Secure; SameSite=Strict")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _auth(self):
            path = urlsplit(self.path).path
            wanted = (store.browser_read_secret if path.startswith("/browse/") else store.secret)
            if self.headers.get("Authorization") != "Bearer " + wanted:
                self._send(403, {"error": "denied"})
                return False
            return True

        def do_GET(self):
            url = urlsplit(self.path)
            if url.path == "/r02-redirect-canary":
                with store._lock:
                    store.redirect_hits += 1
                    store.redirect_auth_header_seen |= bool(self.headers.get("Authorization"))
                self._send(200, {"fictional_canary": True})
                return
            if not self._auth():
                return
            if url.path.startswith("/orders/"):
                key = url.path.removeprefix("/orders/")
                if not key or len(key) > 120 or "/" in key:
                    self._send(422, {"error": "invalid checkout id"})
                    return
                receipt = store.receipt(key)
                self._send(200 if receipt else 404, receipt or {"error": "not_found"})
                return
            if url.path == "/browse/search" and store.redirect_browser_to:
                self.send_response(302)
                self.send_header("Location", store.redirect_browser_to)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if url.path == "/search":
                q = parse_qs(url.query).get("q", [""])[0].lower()
                self._send(200, {"products": [{"sku": store.product["sku"], "name": store.product["name"]}]
                                 if any(word in q for word in ("keyboard", "teclado", "alice")) else []})
            elif url.path == "/product/" + store.product["sku"]:
                self._send(200, store.product)
            elif url.path == "/browse/search":
                q = parse_qs(url.query).get("q", [""])[0].lower()
                found = any(word in q for word in ("keyboard", "teclado", "alice"))
                item = (f'<li data-sku="{html.escape(store.product["sku"])}" '
                        f'data-name="{html.escape(store.product["name"])}">Fictional product</li>') if found else ""
                self._page(200, "<!doctype html><title>Fictional products</title>"
                           f"<ul id='results'>{item}</ul>")
            elif url.path == "/browse/product/" + store.product["sku"]:
                p = store.product
                self._page(200, "<!doctype html><title>Fictional product</title>"
                           f'<article id="product" data-sku="{html.escape(p["sku"])}" '
                           f'data-unit-minor="{p["unit_minor"]}" data-currency="EUR" '
                           f'data-variants="standard,graphite">'
                           f'<h1>{html.escape(p["name"])}</h1><p>{html.escape(p["description"])}</p></article>'
                           # Deliberately hostile page script: a route-guarded
                           # browser must block even same-origin POST effects.
                           '<script>fetch("/commit",{method:"POST",headers:{"Content-Type":"application/json"},'
                           'body:"{}"}).catch(()=>{});</script>')
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._auth():
                return
            try:
                size = int(self.headers.get("Content-Length", "-1"))
                if size < 2 or size > 8192:
                    raise ValueError("invalid request size")
                if getattr(self, "_bounded_merchant_body", False):
                    from .h021_transport import read_body_with_deadline
                    payload = read_body_with_deadline(self, size)
                else:
                    payload = self.rfile.read(size)
                body = json.loads(payload)
                if not isinstance(body, dict):
                    raise ValueError("invalid input")
                if self.path == "/cart":
                    if (body.get("sku") != store.product["sku"]
                            or type(body.get("quantity")) is not int or not 1 <= body["quantity"] <= 5
                            or body.get("variant", "standard") not in store.variant_upcharge_minor
                            or not isinstance(body.get("cart_id"), str) or len(body["cart_id"]) > 100):
                        raise ValueError("bad cart")
                    variant = body.get("variant", "standard")
                    store.put_cart(body["cart_id"], body["sku"], body["quantity"], variant)
                    self._send(200, {"sku": body["sku"], "quantity": body["quantity"],
                                     "variant": variant})
                elif self.path == "/quote":
                    if store.fail_next_quote:
                        store.fail_next_quote = False
                        self._send(503, {"error": "temporary unavailable"})
                    else:
                        self._send(200, store.quote(body["cart_id"], body["recipient"]))
                elif self.path == "/commit":
                    with store._lock:
                        store.submit_attempts += 1
                        if store.commit_delay_seconds:
                            time.sleep(store.commit_delay_seconds)
                        if store.fail_next_submit:
                            store.fail_next_submit = False
                            self._send(503, {"error": "effect uncertain"})
                            return
                        snap = body["snapshot"]
                        expected = store.quote(body["cart_id"], body["recipient"])
                        if (any(snap.get(name) != expected[name] for name in
                                ("sku", "variant", "quantity", "recipient", "merchant_id",
                                 "subtotal_minor", "tax_minor", "shipping_minor",
                                 "discount_minor", "amount_minor", "currency"))
                                or body.get("idempotency_key") != snap.get("checkout_id")
                                or not store.certified_adapter):
                            raise ValueError("unverified checkout")
                        key = body["idempotency_key"]
                        order = store.record_order(key, expected)
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
