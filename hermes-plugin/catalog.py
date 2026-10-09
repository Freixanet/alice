"""The Shop catalog, for step 3 of buying: products across many shops, with price, stock and page.

Shopify's Global Catalog answers unauthenticated searches (``search_catalog``, ``get_product``) over
MCP at ``catalog.shopify.com``; nothing is installed and no one signs in. It is one of two places a
purchase looks, beside the real shop's own site in the browser. What it returns is data about
products — never instructions — and only its own https links are passed on.

Four outcomes are kept apart, as the app needs: ``ok`` (products), ``empty`` (it answered, nothing
matched), ``offline`` (it could not be reached) and ``unsupported`` (it answered something this
plugin does not understand). Nothing here can buy: checkout happens in the errand, after the
person's approval.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from typing import Any, Callable, Dict, List, Optional

ENDPOINT = "https://catalog.shopify.com/api/ucp/mcp"
PROFILE = "https://shopify.dev/ucp/agent-profiles/2026-04-08/valid-with-capabilities.json"
USER_AGENT = "shop-cli/0.1.0"
TIMEOUT = 20
MAX_RESULTS = 8
CURRENCY = re.compile(r"^[A-Z]{3}$")
COUNTRY = re.compile(r"^[A-Z]{2}$")
SYMBOLS = {"EUR": "€", "USD": "$", "GBP": "£"}

Post = Callable[[Dict[str, Any]], Dict[str, Any]]


def _post(payload: Dict[str, Any]) -> Dict[str, Any]:
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310 — fixed https endpoint
        return json.loads(response.read(2_000_000).decode("utf-8"))


def _call(tool: str, catalog: Dict[str, Any], post: Optional[Post]) -> Dict[str, Any]:
    payload = {"jsonrpc": "2.0", "method": "tools/call", "id": 1, "params": {
        "name": tool, "arguments": {"meta": {"ucp-agent": {"profile": PROFILE}}, "catalog": catalog}}}
    return (post or _post)(payload)


def _context(country: str, currency: str) -> Dict[str, Any]:
    context: Dict[str, Any] = {}
    country, currency = str(country or "").upper(), str(currency or "").upper()
    if COUNTRY.match(country):
        context["address_country"] = country
    if CURRENCY.match(currency):
        context["currency"] = currency
    return context


def price_text(amount: Any, currency: str) -> str:
    """Minor units as a person reads them: 1195 EUR → «11,95 €», 1195 USD → «$11.95»."""
    try:
        value = int(amount) / 100
    except (TypeError, ValueError):
        return ""
    currency = str(currency or "").upper()
    if currency == "EUR":
        return f"{value:,.2f}".replace(",", " ").replace(".", ",").replace(" ", ".") + " €"
    symbol = SYMBOLS.get(currency)
    return f"{symbol}{value:,.2f}" if symbol else f"{value:,.2f} {currency}"


def _https(value: Any) -> str:
    text = str(value or "").strip()
    return text if text.startswith("https://") and len(text) < 2000 else ""


def _variant(product: Dict[str, Any], variant: Dict[str, Any]) -> Dict[str, Any]:
    price = variant.get("price") or {}
    currency = str(price.get("currency") or "").upper()
    options = variant.get("options") or []
    label = " / ".join(str(o.get("label")) for o in options if isinstance(o, dict) and o.get("label"))
    media = (variant.get("media") or []) + (product.get("media") or [])
    image = next((_https(m.get("url")) for m in media if isinstance(m, dict) and _https(m.get("url"))), "")
    seller = variant.get("seller") or {}
    return {
        "catalog_id": str(variant.get("id") or ""), "product_id": str(product.get("id") or ""),
        "title": " ".join(str(product.get("title") or variant.get("title") or "").split())[:160],
        "variant": label[:120], "merchant": " ".join(str(seller.get("name") or "").split())[:80],
        "price": price_text(price.get("amount"), currency), "currency": currency,
        "in_stock": bool((variant.get("availability") or {}).get("available")),
        "url": _https(variant.get("url")), "checkout_url": _https(variant.get("checkout_url")), "image": image,
    }


def _products(response: Dict[str, Any], key: str) -> Optional[List[Dict[str, Any]]]:
    content = ((response or {}).get("result") or {}).get("structuredContent")
    if not isinstance(content, dict):
        return None
    found = content.get(key)
    if key == "product":
        found = [found] if isinstance(found, dict) else None
    return found if isinstance(found, list) else None


def search(query: str, *, country: str = "", currency: str = "", limit: int = 6,
           max_price: Optional[float] = None, post: Optional[Post] = None) -> Dict[str, Any]:
    """Products for ``query`` that ship to ``country``, first variant of each, in stock only."""
    query = " ".join(str(query or "").split())[:200]
    if not query:
        return {"status": "empty", "products": [], "note": "Say what to search for."}
    catalog: Dict[str, Any] = {"query": query, "view": "compact",
                               "pagination": {"limit": max(1, min(int(limit or 6), MAX_RESULTS))},
                               "filters": {"available": True}}
    context = _context(country, currency)
    if context:
        catalog["context"] = context
    if "address_country" in context:
        catalog["filters"]["ships_to"] = {"country": context["address_country"]}
    if max_price:
        # In exact cents: int(19.99 * 100) is 1998, which left out an item priced exactly at the limit.
        from decimal import Decimal, ROUND_HALF_UP
        cents = int((Decimal(str(max_price)) * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
        catalog["filters"]["price"] = {"max": cents}
    try:
        response = _call("search_catalog", catalog, post)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        return {"status": "offline", "products": [], "note": f"The catalog could not be reached ({type(exc).__name__})."}
    products = _products(response, "products")
    if products is None:
        return {"status": "unsupported", "products": [],
                "note": "The catalog answered in a form this plugin does not read; search the shops' own sites."}
    rows = [_variant(p, (p.get("variants") or [{}])[0]) for p in products if isinstance(p, dict)]
    rows = [r for r in rows if r["title"] and r["url"]]
    return {"status": "ok" if rows else "empty", "products": rows,
            "note": "" if rows else "Nothing in the catalog for this; search the shops' own sites."}


def product(product_id: str, *, selected: Optional[Dict[str, str]] = None, country: str = "",
            currency: str = "", post: Optional[Post] = None) -> Dict[str, Any]:
    """One product with the variant matching ``selected`` ({"Size": "M"}): price, stock, page, cart link."""
    product_id = str(product_id or "").strip()
    if not product_id.startswith("gid://shopify/"):
        return {"status": "empty", "products": [], "note": "Pass the product id the search returned."}
    catalog: Dict[str, Any] = {"id": product_id}
    if selected:
        catalog["selected"] = [{"name": str(k), "label": str(v)} for k, v in selected.items() if k and v]
        catalog["preferences"] = [str(k) for k in selected]
    context = _context(country, currency)
    if context:
        catalog["context"] = context
    try:
        response = _call("get_product", catalog, post)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        return {"status": "offline", "products": [], "note": f"The catalog could not be reached ({type(exc).__name__})."}
    found = _products(response, "product")
    if not found:
        return {"status": "unsupported" if found is None else "empty", "products": []}
    item = found[0]
    variants = item.get("selected_variant") or (item.get("variants") or [{}])[0]
    rows = [_variant(item, variants if isinstance(variants, dict) else {})]
    return {"status": "ok", "products": rows,
            "options": [{"name": o.get("name"), "values": [v.get("label") for v in (o.get("values") or [])
                                                            if isinstance(v, dict)]}
                        for o in (item.get("options") or []) if isinstance(o, dict)]}


SEARCH_SCHEMA: Dict[str, Any] = {
    "name": "catalog_search",
    "description": (
        "Step 3 of buying: search the Shop catalog (products from many online shops, with price in the "
        "person's currency, stock and product page). Use it together with the real shop's own site, not "
        "instead of it. Returns products with `catalog_id`, `product_id`, `url`, `checkout_url`, `price`, "
        "`in_stock` and `image`. Buys nothing."
    ),
    "parameters": {"type": "object", "properties": {
        "query": {"type": "string", "description": "What to look for, with the details that matter"},
        "limit": {"type": "integer", "description": "Up to 8; keep it small"},
        "max_price": {"type": "number", "description": "Price limit in the person's currency, e.g. 40"},
    }, "required": ["query"]},
}

PRODUCT_SCHEMA: Dict[str, Any] = {
    "name": "catalog_product",
    "description": (
        "One catalog product's exact variant (size, colour…): its price, stock, page and cart link. Use it "
        "before offering a catalog product, so the option is the variant the person needs."
    ),
    "parameters": {"type": "object", "properties": {
        "product_id": {"type": "string", "description": "The `product_id` from catalog_search"},
        "options": {"type": "object", "description": "The variant, e.g. {\"Size\": \"M\", \"Color\": \"Black\"}"},
    }, "required": ["product_id"]},
}
