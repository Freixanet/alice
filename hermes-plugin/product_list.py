"""Products Alice compared, shown as cards in the chat — nothing to buy.

When the person asks to find, compare or research products (not to buy them), Alice shows what
she found the way a shop window would: picture, name, brand and shop, price and the price before
an offer, her pick marked. Then a short paragraph says which to choose for what. Buying stays with
``purchase_options`` and its verified quotes; these cards only point at the product pages.

The app draws the cards from the call's own arguments, so this module only checks them: a card
with no https page or no price would be a dead or misleading card.
"""

from __future__ import annotations

from typing import Any, Dict, List
from urllib.parse import urlsplit

MAX_PRODUCTS = 6

SCHEMA: Dict[str, Any] = {
    "name": "product_list",
    "description": (
        "Show products you found as cards in the chat — picture, name, brand · shop, price, the price "
        "before an offer — when the person asks to find, compare or research products and has not asked "
        "to buy. 2 to 6 products, your pick marked. Call it once your research is done, then write one "
        "short paragraph naming which to choose for what (do not repeat each product's details: the cards "
        "show them). To buy, use the purchase steps instead; these cards buy nothing."
    ),
    "parameters": {"type": "object", "properties": {
        "products": {"type": "array", "minItems": 1, "maxItems": MAX_PRODUCTS, "items": {
            "type": "object", "properties": {
                "title": {"type": "string", "description": "The product's name"},
                "brand": {"type": "string"},
                "merchant": {"type": "string", "description": "The shop or site the price is from"},
                "price": {"type": "string", "description": "As shown, e.g. '69,99 €'"},
                "original_price": {"type": "string", "description": "The price before the offer, when the shop shows one"},
                "url": {"type": "string", "description": "The product page (https) the price was read from"},
                "image": {"type": "string", "description": "The product picture's https address, when known"},
                "recommended": {"type": "boolean", "description": "Your pick (one)"},
            }, "required": ["title", "price", "url"]}},
    }, "required": ["products"]},
}


class ProductListError(ValueError):
    pass


def _https(value: Any) -> str:
    text = str(value or "").strip()
    parts = urlsplit(text)
    return text if parts.scheme == "https" and parts.netloc else ""


def check(args: Dict[str, Any]) -> Dict[str, Any]:
    raw = (args or {}).get("products")
    if not isinstance(raw, list) or not raw:
        raise ProductListError("products must list what you found (1 to 6).")
    if len(raw) > MAX_PRODUCTS:
        raise ProductListError(f"At most {MAX_PRODUCTS} products. Keep the best ones.")
    products: List[Dict[str, Any]] = []
    for index, item in enumerate(raw):
        item = item if isinstance(item, dict) else {}
        where = f"Product {index + 1}"
        title, price = str(item.get("title") or "").strip(), str(item.get("price") or "").strip()
        url = _https(item.get("url"))
        if not title or not price:
            raise ProductListError(f"{where}: title and price are required.")
        if not url:
            raise ProductListError(f"{where}: url must be the product page (https) the price came from.")
        products.append({"title": title, "price": price, "url": url,
                         "brand": str(item.get("brand") or "").strip(),
                         "merchant": str(item.get("merchant") or "").strip(),
                         "original_price": str(item.get("original_price") or "").strip(),
                         "image": _https(item.get("image")),
                         "recommended": bool(item.get("recommended"))})
    if sum(p["recommended"] for p in products) > 1:
        raise ProductListError("Mark one pick at most.")
    return {"ok": True, "shown": len(products),
            "next": "The cards are on screen. Now write one short paragraph: which to choose for what."}
