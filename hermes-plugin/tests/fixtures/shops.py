"""Three fictional shops on three platforms, for the shop engine (shop_engine.py).

Each shop answers ``request(method, url, body) -> (status, content_type, body, headers)`` and keeps
its own basket, so the same object serves the jsdom page in the unit tests and a real Chrome whose
traffic is intercepted (scripts/verify-shops.py). No real shop, account or payment is involved.

* ``ShopifyLike`` — Shopify markup and its AJAX API (/products/<h>.js, /cart/add.js, /cart.js,
  /search/suggest.json). Variants with their own prices; one sold out.
* ``WooLike`` — WooCommerce markup and the Store API (/wp-json/wc/store/v1/...). A variable product.
* ``Generic`` — no platform: JSON-LD, a cookie banner over the page, its own search form, a size
  select, an add button that answers with a toast, a cart page in plain HTML, a coupon field and a
  checkout summary with subtotal, shipping and total.
"""
from __future__ import annotations

import json
import subprocess
import shutil
import os
from html import escape
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlsplit

Response = Tuple[int, str, str, Dict[str, str]]


def plain(text: str) -> str:
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFKD", str(text)) if not unicodedata.combining(c)).lower()


def euros(cents: int) -> str:
    return f"{cents / 100:,.2f}".replace(",", " ").replace(".", ",").replace(" ", ".") + " €"


def html(body: str, *, head: str = "", body_class: str = "") -> Response:
    return (200, "text/html; charset=utf-8",
            f"<!doctype html><html lang=es><head><meta charset=utf-8>{head}</head><body class=\"{body_class}\">{body}</body></html>", {})


def as_json(value: Any, status: int = 200, headers: Optional[Dict[str, str]] = None) -> Response:
    return (status, "application/json", json.dumps(value), headers or {})


NOT_FOUND: Response = (404, "text/html", "<h1>404</h1>", {})


class Shop:
    host = ""

    def __init__(self):
        self.cart: List[Dict[str, Any]] = []
        self.coupon = ""
        self.paid = False

    @property
    def base(self) -> str:
        return "https://" + self.host

    def request(self, method: str, url: str, body: str = "") -> Response:
        raise NotImplementedError


# ── Shopify-like ─────────────────────────────────────────────────────────────────


class ShopifyLike(Shop):
    host = "tienda-uno.example"
    PRODUCTS = [
        {"id": 101, "handle": "creatina-creapure", "title": "Creatina Creapure Monohidrato",
         "variants": [{"id": 1001, "title": "300 g", "price": 2499, "available": True},
                      {"id": 1002, "title": "500 g", "price": 3499, "available": True},
                      {"id": 1003, "title": "1 kg", "price": 5999, "available": False}]},
        {"id": 102, "handle": "camiseta-tecnica", "title": "Camiseta técnica",
         "variants": [{"id": 2001, "title": "Default Title", "price": 1990, "available": True}]},
    ]

    def product(self, handle: str) -> Optional[Dict[str, Any]]:
        return next((p for p in self.PRODUCTS if p["handle"] == handle), None)

    def variant(self, vid: int) -> Optional[Tuple[Dict[str, Any], Dict[str, Any]]]:
        for p in self.PRODUCTS:
            for v in p["variants"]:
                if v["id"] == vid:
                    return p, v
        return None

    def head(self) -> str:
        return ("<script>window.Shopify={shop:'tienda-uno.myshopify.com',routes:{root:'/'}};</script>"
                "<link rel=stylesheet href='https://cdn.shopify.com/s/files/theme.css'>")

    def request(self, method: str, url: str, body: str = "") -> Response:
        parts = urlsplit(url)
        path, query = parts.path, parse_qs(parts.query)
        if path == "/":
            return html("<header><form action='/search' method=get role=search><input type=search name=q></form>"
                        "<a href='/cart'>Carrito</a></header><h1>Tienda Uno</h1>", head=self.head())
        if path == "/search/suggest.json":
            q = plain((query.get("q") or [""])[0])
            found = [{"title": p["title"], "url": "/products/" + p["handle"]} for p in self.PRODUCTS
                     if all(w in plain(p["title"]) for w in q.split())]
            return as_json({"resources": {"results": {"products": found}}})
        if path.startswith("/products/") and path.endswith(".js"):
            p = self.product(path[len("/products/"):-3])
            if not p:
                return as_json({"error": "not found"}, 404)
            return as_json({"id": p["id"], "handle": p["handle"], "title": p["title"],
                            "variants": [{**v, "options": [v["title"]]} for v in p["variants"]]})
        if path.startswith("/products/"):
            p = self.product(path[len("/products/"):].strip("/"))
            if not p:
                return NOT_FOUND
            first = p["variants"][0]
            options = "".join(f"<option value='{v['id']}'>{escape(v['title'])}</option>" for v in p["variants"])
            picker = "" if len(p["variants"]) == 1 else f"<select name=id>{options}</select>"
            return html(f"<a href='/cart'>Carrito</a><h1>{escape(p['title'])}</h1><span class=price>{euros(first['price'])}</span>"
                        f"<form action='/cart/add' method=post>{picker}<input type=number name=quantity value=1>"
                        "<button type=submit name=add>Añadir al carrito</button></form>", head=self.head())
        if path == "/cart/add.js" and method == "POST":
            items = json.loads(body or "{}").get("items") or []
            for item in items:
                found = self.variant(int(item["id"]))
                if not found or not found[1]["available"]:
                    return as_json({"status": 422, "description": "Agotado"}, 422)
                line = next((l for l in self.cart if l["variant_id"] == item["id"]), None)
                if line:
                    line["quantity"] += int(item.get("quantity") or 1)
                else:
                    self.cart.append({"variant_id": int(item["id"]), "quantity": int(item.get("quantity") or 1)})
            return as_json({"items": items})
        if path == "/cart.js":
            items = []
            for line in self.cart:
                p, v = self.variant(line["variant_id"])
                items.append({"variant_id": v["id"], "quantity": line["quantity"], "price": v["price"],
                              "final_price": v["price"], "product_title": p["title"], "title": p["title"] + " - " + v["title"]})
            return as_json({"currency": "EUR", "items": items,
                            "total_price": sum(i["price"] * i["quantity"] for i in items)})
        if path == "/cart":
            rows = "".join(f"<div class=cart-item><span>{escape(p['title'])} - {escape(v['title'])}</span>"
                           f"<input type=number name='updates[]' value={l['quantity']}><span class=price>{euros(v['price'])}</span></div>"
                           for l in self.cart for p, v in [self.variant(l["variant_id"])])
            return html(f"<h1>Carrito</h1>{rows}<a href='/checkout'>Finalizar compra</a>", head=self.head())
        if path == "/checkout":
            subtotal = sum(self.variant(l["variant_id"])[1]["price"] * l["quantity"] for l in self.cart)
            return html(f"<h2>Resumen</h2><dl><dt>Subtotal</dt><dd>{euros(subtotal)}</dd><dt>Envío</dt><dd>{euros(495)}</dd></dl>"
                        f"<p class=total-line><span>Total</span> <strong>{euros(subtotal + 495)}</strong></p>"
                        "<button id=pay onclick='window.paid=true'>Pagar ahora</button>", head=self.head())
        return NOT_FOUND


# ── WooCommerce-like ─────────────────────────────────────────────────────────────


class WooLike(Shop):
    host = "tienda-dos.example"
    PRODUCT = {"id": 301, "slug": "proteina-whey", "name": "Proteína Whey Isolate", "type": "variable"}
    VARIATIONS = [{"id": 311, "label": "Chocolate", "price": 3290, "stock": True},
                  {"id": 312, "label": "Vainilla", "price": 3290, "stock": True},
                  {"id": 313, "label": "Fresa", "price": 3490, "stock": False}]

    def prices(self, cents: int) -> Dict[str, Any]:
        return {"price": str(cents), "regular_price": str(cents), "currency_code": "EUR", "currency_minor_unit": 2}

    def store_product(self) -> Dict[str, Any]:
        low = min(v["price"] for v in self.VARIATIONS)
        return {**self.PRODUCT, "permalink": self.base + "/producto/" + self.PRODUCT["slug"] + "/", "is_in_stock": True,
                "prices": self.prices(low)}

    def store_variation(self, v: Dict[str, Any]) -> Dict[str, Any]:
        return {"id": v["id"], "name": self.PRODUCT["name"] + " - " + v["label"], "type": "variation", "is_in_stock": v["stock"],
                "attributes": [{"name": "Sabor", "value": v["label"]}], "prices": self.prices(v["price"])}

    def by_id(self, vid: int) -> Optional[Dict[str, Any]]:
        return next((v for v in self.VARIATIONS if v["id"] == vid), None)

    def request(self, method: str, url: str, body: str = "") -> Response:
        parts = urlsplit(url)
        path, query = parts.path, parse_qs(parts.query)
        woo = "woocommerce woocommerce-page"
        head = "<link rel=stylesheet href='/wp-content/plugins/woocommerce/assets/css/woocommerce.css'>"
        if path == "/":
            return html("<form role=search method=get action='/'><input type=search name=s><input type=hidden name=post_type value=product></form>",
                        head=head, body_class=woo)
        if path == "/wp-json/wc/store/v1/products":
            if (query.get("type") or [""])[0] == "variation":
                return as_json([self.store_variation(v) for v in self.VARIATIONS])
            slug, search = (query.get("slug") or [""])[0], plain((query.get("search") or [""])[0])
            if slug == self.PRODUCT["slug"] or (search and all(w in plain(self.PRODUCT["name"]) for w in search.split())):
                return as_json([self.store_product()])
            return as_json([])
        if path == "/wp-json/wc/store/v1/cart/add-item" and method == "POST":
            data = json.loads(body or "{}")
            v = self.by_id(int(data.get("id") or 0))
            if not v or not v["stock"]:
                return as_json({"code": "woocommerce_rest_product_out_of_stock"}, 400)
            line = next((l for l in self.cart if l["id"] == v["id"]), None)
            if line:
                line["quantity"] += int(data.get("quantity") or 1)
            else:
                self.cart.append({"id": v["id"], "quantity": int(data.get("quantity") or 1)})
            return as_json({"items_count": sum(l["quantity"] for l in self.cart)})
        if path == "/wp-json/wc/store/v1/cart":
            items = [{"id": l["id"], "quantity": l["quantity"], "name": self.PRODUCT["name"],
                      "prices": self.prices(self.by_id(l["id"])["price"])} for l in self.cart]
            return as_json({"items": items}, headers={"Nonce": "fixture-nonce"})
        if path == "/producto/" + self.PRODUCT["slug"] + "/":
            options = "".join(f"<option value='{escape(v['label'])}'>{escape(v['label'])}</option>" for v in self.VARIATIONS)
            return html(f"<h1 class=product_title>{escape(self.PRODUCT['name'])}</h1><p class=price>{euros(3290)} – {euros(3490)}</p>"
                        f"<form class=variations_form><select name=attribute_sabor><option value=''>Elige una opción</option>{options}</select>"
                        "<input type=number name=quantity value=1><button type=submit class=single_add_to_cart_button>Añadir al carrito</button></form>",
                        head=head, body_class=woo + " single-product")
        if path == "/finalizar-compra/":
            subtotal = sum(self.by_id(l["id"])["price"] * l["quantity"] for l in self.cart)
            return html(f"<table class=shop_table><tr class=cart-subtotal><th>Subtotal</th><td>{euros(subtotal)}</td></tr>"
                        f"<tr class=shipping><th>Envío</th><td>Envío gratuito</td></tr>"
                        f"<tr class=order-total><th>Total</th><td><strong>{euros(subtotal)}</strong></td></tr></table>",
                        head=head, body_class=woo)
        return NOT_FOUND


# ── A shop on no platform ────────────────────────────────────────────────────────


class Generic(Shop):
    host = "tienda-tres.example"
    PRODUCTS = {
        "zapatillas-trail-x": {"name": "Zapatillas Trail X", "sizes": {"41": 8995, "42": 8995, "43": 9495, "44": None}},
        "calcetines-trail": {"name": "Calcetines Trail", "sizes": {}, "price": 1250},
    }
    BANNER = ("<div id=cookie-banner class=cookie-consent style='position:fixed'>Usamos cookies."
              "<button onclick=\"this.parentElement.hidden=true\">Configurar</button>"
              "<button onclick=\"this.parentElement.hidden=true;window.consented=true\">Aceptar todo</button></div>")

    def unit(self, slug: str, size: str) -> Optional[int]:
        p = self.PRODUCTS[slug]
        return p["sizes"].get(size) if p["sizes"] else p["price"]

    def request(self, method: str, url: str, body: str = "") -> Response:
        parts = urlsplit(url)
        path, query = parts.path, parse_qs(parts.query)
        nav = "<header><a href='/cesta' class=basket-link>Mi cesta</a></header>"
        if path == "/":
            return html(self.BANNER + nav + "<form role=search action='/busqueda' method=get><input name=buscar placeholder='Buscar productos'>"
                        "<button>Buscar</button></form><h1>Tienda Tres</h1>")
        if path == "/busqueda":
            q = plain((query.get("buscar") or [""])[0])
            cards = "".join(f"<li class=product-card><a href='/p/{slug}'><h3>{escape(p['name'])}</h3></a>"
                            f"<span class=precio>{euros(min(c for c in p['sizes'].values() if c) if p['sizes'] else p['price'])}</span></li>"
                            for slug, p in self.PRODUCTS.items() if all(w in plain(p["name"]) for w in q.split()))
            return html(self.BANNER + nav + f"<h1>Resultados</h1><ul class=results>{cards}</ul><footer><a href='/p/zapatillas-trail-x'>Destacado</a></footer>")
        if path.startswith("/p/"):
            slug = path[3:]
            if slug not in self.PRODUCTS:
                return NOT_FOUND
            p = self.PRODUCTS[slug]
            offers = ([{"@type": "Offer", "name": s, "price": f"{c / 100:.2f}" if c else "0", "priceCurrency": "EUR",
                        "availability": "https://schema.org/" + ("InStock" if c else "OutOfStock")} for s, c in p["sizes"].items()]
                      if p["sizes"] else [{"@type": "Offer", "price": f"{p['price'] / 100:.2f}", "priceCurrency": "EUR",
                                           "availability": "https://schema.org/InStock"}])
            ld = {"@context": "https://schema.org", "@type": "Product", "name": p["name"], "sku": slug,
                  "image": self.base + "/img/" + slug + ".jpg", "offers": offers}
            first = next((c for c in p["sizes"].values() if c), None) if p["sizes"] else p["price"]
            sizes = "".join(f"<option value='{s}'{' disabled' if not c else ''}>Talla {s}{' — agotada' if not c else ''}</option>"
                            for s, c in p["sizes"].items())
            prices = json.dumps({s: c for s, c in p["sizes"].items()})
            picker = (f"<label>Talla <select id=talla onchange=\"const c={prices}[this.value];if(c)document.querySelector('.precio-actual').textContent=(c/100).toFixed(2).replace('.',',')+' €'\">"
                      f"<option value=''>Elige talla</option>{sizes}</select></label>" if p["sizes"] else "")
            script = ("<script>async function add(){const t=document.querySelector('#talla');if(t&&!t.value){alert('Elige talla');return}"
                      "const q=document.querySelector('input[name=cantidad]').value;"
                      f"await fetch('/cesta/add',{{method:'POST',body:JSON.stringify({{slug:'{slug}',size:t?t.value:'',qty:Number(q)}})}});"
                      "document.querySelector('#toast').hidden=false}</script>")
            return html(self.BANNER + nav + f"<main><h1>{escape(p['name'])}</h1><p><s>{euros(12000)}</s> "
                        f"<span class=precio-actual>{euros(first)}</span></p><p class=unit>{euros(first * 2)}/kg</p>{picker}"
                        "<input type=number name=cantidad value=1 min=1>"
                        "<button class=btn-comprar onclick='add()'>Añadir a la cesta</button>"
                        "<div id=toast hidden>Añadido. <a href='/cesta'>Ver cesta</a></div></main>" + script,
                        head=f"<script type='application/ld+json'>{json.dumps(ld)}</script>")
        if path == "/cesta/add" and method == "POST":
            data = json.loads(body or "{}")
            if self.unit(data["slug"], data.get("size") or "") is None:
                return (409, "text/plain", "agotado", {})
            self.cart.append({"slug": data["slug"], "size": data.get("size") or "", "qty": int(data.get("qty") or 1)})
            return (200, "text/plain", "ok", {})
        if path == "/cesta/cupon" and method == "POST":
            code = json.loads(body or "{}").get("code")
            self.coupon = code if code == "PUBLICO10" else ""
            return as_json({"ok": bool(self.coupon)})
        if path == "/cesta":
            factor = 0.9 if self.coupon else 1
            rows = ""
            for l in self.cart:
                unit = int(round(self.unit(l["slug"], l["size"]) * factor))
                name = self.PRODUCTS[l["slug"]]["name"] + (f" · Talla {l['size']}" if l["size"] else "")
                rows += (f"<tr class=cart-row><td class=name>{escape(name)}</td><td><input type=number class=qty value={l['qty']}></td>"
                         f"<td class=unit-price>{euros(unit)}</td><td class=line-total>{euros(unit * l['qty'])}</td></tr>")
            script = ("<script>async function cupon(){const c=document.querySelector('#cupon').value;"
                      "const r=await (await fetch('/cesta/cupon',{method:'POST',body:JSON.stringify({code:c})})).json();"
                      "if(r.ok){for(const td of document.querySelectorAll('.unit-price')){const v=Number(td.textContent.replace(/[^0-9,]/g,'').replace(',','.'));"
                      "td.textContent=(Math.round(v*90)/100).toFixed(2).replace('.',',')+' €'}}"
                      "else document.querySelector('#cupon-error').hidden=false}</script>")
            return html(self.BANNER + nav + f"<h1>Tu cesta</h1><table><tbody>{rows}</tbody></table>"
                        "<div class=promo><input id=cupon name=codigo_descuento placeholder='Código de descuento'>"
                        "<button onclick='cupon()'>Aplicar</button><p id=cupon-error hidden>Código no válido</p></div>"
                        "<a href='/pedido'>Tramitar pedido</a>" + script)
        if path == "/pedido":
            factor = 0.9 if self.coupon else 1
            subtotal = sum(int(round(self.unit(l["slug"], l["size"]) * factor)) * l["qty"] for l in self.cart)
            return html(nav + f"<section class=resumen><div><span>Subtotal</span> <span>{euros(subtotal)}</span></div>"
                        f"<div><span>Gastos de envío</span> <span>{euros(399)}</span></div>"
                        f"<div><span>Ahorras</span> <span>{euros(500)}</span></div>"
                        f"<div class=grand><span>Total a pagar</span> <b>{euros(subtotal + 399)}</b></div></section>"
                        "<button onclick='window.paid=true'>Pagar ahora</button>")
        return NOT_FOUND


SHOPS = (ShopifyLike, WooLike, Generic)


class Router:
    """Answers every request of a page from the fixture shops; anything else is refused."""

    def __init__(self, *shops: Shop):
        self.shops = {s.host: s for s in shops}

    def request(self, method: str, url: str, body: str = "") -> Response:
        shop = self.shops.get(urlsplit(url).hostname or "")
        if shop is None or urlsplit(url).scheme != "https":
            return (502, "text/plain", "blocked by fixture", {})
        return shop.request(method, url, body)


# ── A jsdom page driven from Python ──────────────────────────────────────────────

HARNESS = Path(__file__).with_name("js_page.cjs")


def jsdom_available() -> bool:
    if not shutil.which("node"):
        return False
    probe = subprocess.run(["node", "-e", "require(require.resolve('jsdom',{paths:[process.cwd(),%s,...(process.env.NODE_PATH||'').split(require('path').delimiter)]}))"
                            % json.dumps(str(HARNESS.parents[3]))], capture_output=True, cwd=str(HARNESS.parents[3]))
    return probe.returncode == 0


class JsPage:
    """``evaluate``/``goto``/``url`` as shop_engine.Page needs them, over a jsdom page whose every
    request is answered by ``router``."""

    def __init__(self, router: Router):
        self.router = router
        self.requests: List[Tuple[str, str]] = []
        self.proc = subprocess.Popen(["node", str(HARNESS)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, cwd=str(HARNESS.parents[3]), env=os.environ.copy())
        self.current = "about:blank"

    def _send(self, msg: Dict[str, Any]) -> Any:
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("jsdom page closed")
            reply = json.loads(line)
            if reply.get("op") == "request":
                self.requests.append((reply["method"], reply["url"]))
                status, ctype, body, headers = self.router.request(reply["method"], reply["url"], reply.get("body") or "")
                self.proc.stdin.write(json.dumps({"op": "response", "id": reply["id"], "status": status, "body": body,
                                                  "headers": {"Content-Type": ctype, **headers}, "url": reply["url"]}) + "\n")
                self.proc.stdin.flush()
                continue
            if reply.get("error"):
                raise ValueError(reply["error"].splitlines()[0])
            return reply.get("value")

    def goto(self, url: str) -> None:
        out = self._send({"op": "load", "url": url})
        self.current = out["url"]
        if not out.get("ok"):
            raise ValueError("La página no existe: " + url)

    def evaluate(self, script: str) -> Any:
        return self._send({"op": "eval", "js": script})

    def url(self) -> str:
        return self.current

    def close(self) -> None:
        try:
            self._send({"op": "quit"})
        except Exception:  # noqa: BLE001
            pass
        self.proc.kill()
        self.proc.wait()
        for stream in (self.proc.stdin, self.proc.stdout):
            try:
                stream.close()
            except Exception:  # noqa: BLE001
                pass
