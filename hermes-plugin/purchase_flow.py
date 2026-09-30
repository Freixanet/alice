"""A purchase in the chat, before anything is bought: steps 1–6 of Alice's way of buying.

    1 clarify what exactly (size, model, quantity, variant) before searching
    2 the person's context: country, currency, shops and cards used before (`context_block`)
    3 search the Shop catalog (catalog.py) and the real shop, in parallel
    4 keep only what can be bought: a real https page, in stock, priced in their currency (`verify`)
    5 show the options as product cards, with a recommendation (`purchase_options`)
    6 the person taps one («[elección:<id>]») or says which in words

Up to here no cart and no payment is touched: the chat may search and read pages, but a browser
action that adds to a cart or pays is refused (`is_cart_action`), and `errand_start` for a purchase
needs a chosen option. The errand (errands.py) then prepares that exact option — its page, variant,
quantity and price, carried by the plugin, not retyped by the model — and nothing is paid without
the person's approval of the checkout. See docs/purchases.md.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlsplit

KEEP = 3 * 24 * 3600
MAX_OPTIONS = 6
CHANNELS = ("catalog", "browser")
CURRENCY = re.compile(r"^[A-Z]{3}$")
CHOICE = re.compile(r"^\s*(?:@[\w-]+\s+)?\[elecci[oó]n:([0-9a-f]{8}-[1-9])\]")
# A request to buy: the chat clarifies and shows options first; nothing starts on its own.
PURCHASE_REQUEST = re.compile(
    r"\b(c[oó]mpra(me|lo|la|los|las)?|comprar|p[ií]de(me|lo|la)?|pedir|carrito|cesta|a[nñ]ade\w*\s+al\s+carrito"
    r"|buy|order|purchase)\b", re.I)
# What a button that fills a cart or goes to checkout says (the paying ones are errands.PAY_WORDS).
CART_WORDS = re.compile(
    r"(a[nñ]adir (a la cesta|al carrito)|add to (cart|bag|basket)|agregar al carrito|a la cesta|al carrito"
    r"|comprar ahora|buy now|checkout|tramitar|finalizar (la )?compra|proceed to|ir a (la )?caja|/cart/add)", re.I)
BROWSER_PRESSES = ("browser_exec", "browser_click", "browser_press", "browser_type")


# ── Store: the options shown in each chat, and which one was chosen ────────────


def _path(home: Path) -> Path:
    folder = Path(home) / ".alice"
    folder.mkdir(parents=True, exist_ok=True)
    return folder / "purchase-options.json"


@contextmanager
def _locked(home: Path):
    path = _path(home)
    with open(path.with_suffix(".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield path
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _read(path: Path) -> List[Dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def _write(path: Path, sets: List[Dict[str, Any]]) -> None:
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(sets, handle, ensure_ascii=False)
    os.replace(tmp, path)


def _clean(value: Any, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def set_key(options: Iterable[Dict[str, Any]]) -> str:
    """Shared with iOS: pages plus the variant, quantity, price and currency identify this offer.
    Repeating a search for another variant must not overwrite an earlier option's meaning."""
    rows = [[str(o.get(k) or "").strip() for k in ("url", "variant")]
            + [str(o.get("qty") or 1)]
            + [str(o.get(k) or "").strip() for k in ("price", "currency")]
            for o in options if isinstance(o, dict)]
    encoded = json.dumps(rows, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:8]



def verify(raw: Any, currency: str = "", picture: Optional[Callable[[str], str]] = None
           ) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """Step 4: what can be bought, and what was left out and why. An option's id is its set's key
    and its position among those given, so the app and the plugin name it the same way."""
    options = [o for o in (raw if isinstance(raw, list) else []) if isinstance(o, dict)][:MAX_OPTIONS]
    key = set_key(options)
    expected = str(currency or "").upper()
    kept: List[Dict[str, Any]] = []
    discarded: List[Dict[str, str]] = []
    for index, option in enumerate(options):
        title = _clean(option.get("title"), 160)
        url = str(option.get("url") or "").strip()
        price = _clean(option.get("price"), 40)
        money = _clean(option.get("currency"), 8).upper()
        channel = str(option.get("channel") or "browser").lower()
        problem = ""
        try:
            parts = urlsplit(url)
            valid_page = parts.scheme == "https" and bool(parts.hostname) and not parts.username and not parts.password
            qty = int(option.get("qty") or 1)
        except (TypeError, ValueError):
            valid_page = False
            qty = 1
        if not title:
            problem = "sin nombre"
        elif not valid_page:
            problem = "sin página https del producto"
        elif not any(ch.isdigit() for ch in price):
            problem = "sin precio"
        elif not CURRENCY.match(money):
            problem = "sin moneda (código ISO, p. ej. EUR)"
        elif expected and money != expected:
            problem = f"el precio no está en {expected}"
        elif option.get("in_stock") is not True:
            problem = "sin stock comprobado"
        elif channel not in CHANNELS:
            problem = "canal desconocido"
        if problem:
            discarded.append({"title": title or url[:80], "why": problem})
            continue
        image = str(option.get("image") or "").strip()
        if not image.startswith("https://") and picture is not None:
            try:
                image = picture(url) or ""
            except Exception:  # noqa: BLE001 — a picture is a nicety, never a reason to fail
                image = ""
        checkout_url = str(option.get("checkout_url") or "").strip()
        kept.append({
            "id": f"{key}-{index + 1}", "title": title, "merchant": _clean(option.get("merchant"), 80),
            "variant": _clean(option.get("variant"), 120), "qty": max(1, min(qty, 20)),
            "price": price, "currency": money, "url": url, "image": image if image.startswith("https://") else "",
            "channel": channel, "catalog_id": _clean(option.get("catalog_id"), 120),
            "checkout_url": checkout_url if checkout_url.startswith("https://") else "",
            "recommended": bool(option.get("recommended")), "why": _clean(option.get("why"), 200),
        })
    # One recommendation at most: the first the model marked.
    marked = False
    for option in kept:
        option["recommended"] = option["recommended"] and not marked
        marked = marked or option["recommended"]
    return kept, discarded


def present(home: Path, session: str, args: Dict[str, Any], *, currency: str = "", now: Optional[float] = None,
            picture: Optional[Callable[[str], str]] = None) -> Dict[str, Any]:
    """`purchase_options`: keeps the verified options for the app to draw and for the choice to find."""
    now = now or time.time()
    kept, discarded = verify((args or {}).get("options"), currency, picture)
    if not kept:
        return {"ok": False, "discarded": discarded, "error": (
            "Ninguna opción se pudo verificar como comprable. No enseñes nada: di en una línea qué ha "
            "fallado (sin stock, sin precio en su moneda…) y propón cómo seguir (otra tienda, otra "
            "variante, otro presupuesto).")}
    key = kept[0]["id"].split("-")[0]
    with _locked(home) as path:
        sets = [s for s in _read(path) if now - float(s.get("at") or 0) < KEEP and not (s.get("key") == key and s.get("session") == _clean(session, 160))]
        sets.append({"key": key, "session": _clean(session, 160), "options": kept, "chosen": None, "at": now})
        _write(path, sets)
    return {"ok": True, "set": key, "options": [{"id": o["id"], "title": o["title"], "price": o["price"]}
                                                for o in kept],
            "discarded": discarded,
            "next": ("La persona ve las tarjetas. Termina tu turno con una o dos líneas: cuál recomiendas y "
                     "por qué. No preguntes nada más ni prepares la compra hasta que elija.")}


def options_set(home: Path, key: str, session: Optional[str] = None,
                now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    now = now or time.time()
    matches = [s for s in _read(_path(home)) if s.get("key") == key
               and now - float(s.get("at") or 0) < KEEP
               and (session is None or s.get("session") == session)]
    # Older callers without a session must never receive another chat's ambiguous set.
    return matches[0] if len(matches) == 1 else None


def option(home: Path, option_id: str) -> Optional[Dict[str, Any]]:
    key = str(option_id or "").split("-")[0]
    found = options_set(home, key)
    return next((o for o in (found or {}).get("options") or [] if o.get("id") == option_id), None)


def open_options(home: Path, session: str, now: Optional[float] = None) -> bool:
    """Options were shown in this chat and none has been chosen yet."""
    now = now or time.time()
    return any(s.get("session") == session and not s.get("chosen") and now - float(s.get("at") or 0) < KEEP
               for s in _read(_path(home)))


def choose(home: Path, session: str, option_id: str, now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """Step 6: the option, when it was shown in this chat; marked as the one chosen."""
    now = now or time.time()
    key = str(option_id or "").split("-")[0]
    with _locked(home) as path:
        sets = _read(path)
        found = next((s for s in sets if s.get("key") == key and s.get("session") == session
                      and now - float(s.get("at") or 0) < KEEP), None)
        picked = next((o for o in (found or {}).get("options") or [] if o.get("id") == option_id), None)
        if picked is None:
            return None
        found["chosen"] = option_id
        _write(path, sets)
    return picked


def chosen_id(text: Any) -> Optional[str]:
    found = CHOICE.match(str(text or ""))
    return found.group(1) if found else None


def is_purchase_request(text: Any) -> bool:
    text = " ".join(str(text or "").split())
    return bool(text) and not text.startswith(("[respuesta:", "[elecci", "[Continuing")) \
        and bool(PURCHASE_REQUEST.search(text))


def is_cart_action(tool_name: str, args: Any) -> bool:
    """A browser action that puts something in a cart or heads to checkout: the errand's, never the chat's."""
    if tool_name not in BROWSER_PRESSES:
        return False
    text = " ".join(str(v) for v in args.values()) if isinstance(args, dict) else str(args or "")
    return bool(CART_WORDS.search(text))


# ── What the errand is given ───────────────────────────────────────────────────


def offer(chosen: Dict[str, Any]) -> Dict[str, Any]:
    """The chosen option as the errand keeps it: exactly what to buy, where and for how much."""
    keys = ("title", "merchant", "variant", "qty", "price", "currency", "url", "checkout_url", "channel", "catalog_id")
    return {"option_id": chosen["id"], **{k: chosen.get(k) for k in keys}}


def task(chosen: Dict[str, Any]) -> str:
    variant = f" ({chosen['variant']})" if chosen.get("variant") else ""
    shop = f" en {chosen['merchant']}" if chosen.get("merchant") else ""
    return (f"Comprar {chosen['title']}{variant} × {chosen.get('qty') or 1}{shop} por {chosen['price']}: "
            f"{chosen['url']}")


def title(chosen: Dict[str, Any]) -> str:
    shop = f" en {chosen['merchant']}" if chosen.get("merchant") else ""
    return _clean(f"Comprar {chosen['title']}{shop}", 80)


# ── Step 2: the person's context ───────────────────────────────────────────────


def context_block(details: Dict[str, str], cards: List[Dict[str, Any]], recent: List[Dict[str, Any]]) -> str:
    """What the chat knows before searching, and what is still missing. Card labels only, never numbers."""
    country = details.get("country", "")
    currency = details.get("currency", "")
    where = ", ".join(v for v in (details.get("city"), details.get("postcode")) if v)
    shops = []
    for entry in recent:
        name = entry.get("merchant") or entry.get("site")
        if name and name not in shops:
            shops.append(name)
    last_card = next((e.get("card_label") for e in recent if e.get("card_label")), "")
    labels = [c.get("label") for c in cards if c.get("label")]
    lines = [
        f"país: {country or 'no lo sé'}", f"moneda: {currency or 'no lo sé'}",
        f"envío a: {where or 'sin dirección guardada'}",
        f"tiendas donde ya compró: {', '.join(shops[:5]) or 'ninguna todavía'}",
        f"tarjetas guardadas: {', '.join(labels) or 'ninguna'}" + (f" (la última usada: {last_card})" if last_card else ""),
    ]
    missing = [name for name, value in (("country", country), ("currency", currency)) if not value]
    ask = (f" Si falta {' y '.join(missing)}, pregúntalo una vez con `ask_person` (field: {', '.join(missing)}) "
           "y se guarda." if missing else "")
    return "[Alice · compra] Lo que sé de la persona — " + "; ".join(lines) + "." + ask


def turn_note(block: str) -> str:
    return (block + " Sigue los pasos de «Comprar»: aclara lo imprescindible antes de buscar, busca en el "
            "catálogo (`catalog_search`) y en la tienda real, enseña solo lo comprable con "
            "`purchase_options` y espera a que elija. En el chat no se llena ningún carrito ni se paga.")


def chosen_note(started: Dict[str, Any], chosen: Dict[str, Any]) -> str:
    return (f"[Alice] La persona ha elegido «{chosen['title']}» ({chosen.get('variant') or 'sin variante'}, "
            f"{chosen['price']}, {chosen.get('merchant') or 'la tienda'}). Ya he puesto en marcha la compra "
            f"(id {started.get('errand_id')}). Llama a `errand_start` con `option_id` {chosen['id']} para que se "
            "vea su tarjeta y responde en una sola línea que la preparas y que le enseñarás el total antes de "
            "pagar. No abras el navegador aquí.")


CART_BLOCK = ("En el chat no se llena un carrito ni se va al checkout. Enseña las opciones verificadas con "
              "`purchase_options`; cuando la persona elija una, la compra la prepara su recado.")
NEEDS_CHOICE = ("Una compra empieza por una opción elegida: enseña primero las opciones verificadas con "
                "`purchase_options` y espera a que la persona elija; luego llama a `errand_start` con su "
                "`option_id`.")
UNKNOWN_OPTION = ("Esa opción no se ha enseñado en esta conversación (o ya caducó). Vuelve a enseñar las "
                  "opciones con `purchase_options`.")


OPTIONS_SCHEMA: Dict[str, Any] = {
    "name": "purchase_options",
    "description": (
        "Step 5 of buying, in the chat: show the person, as product cards, the options you verified — a real "
        "product page (https), in stock, priced in their currency — with your recommendation marked. 1 to 6 "
        "options, once per search. Nothing is bought. Options the plugin cannot verify are left out and "
        "listed in `discarded`. Then end your turn: the person taps one or says which, and the purchase "
        "starts with `errand_start` and that `option_id`."
    ),
    "parameters": {"type": "object", "properties": {
        "options": {"type": "array", "maxItems": MAX_OPTIONS, "items": {"type": "object", "properties": {
            "title": {"type": "string", "description": "The product's name as the shop gives it"},
            "merchant": {"type": "string", "description": "The shop, e.g. 'HSN'"},
            "variant": {"type": "string", "description": "Size, colour, capacity… exactly as it will be bought"},
            "qty": {"type": "integer"},
            "price": {"type": "string", "description": "As the page shows it, e.g. '27,98 €'"},
            "currency": {"type": "string", "description": "ISO code, e.g. EUR"},
            "url": {"type": "string", "description": "The product page (https), read from the shop or the catalog"},
            "image": {"type": "string", "description": "The product picture's https address, when known"},
            "in_stock": {"type": "boolean", "description": "True only when you saw it available"},
            "channel": {"type": "string", "enum": list(CHANNELS),
                        "description": "catalog: found with catalog_search; browser: on the shop's own site"},
            "catalog_id": {"type": "string", "description": "The catalog variant id, for catalog options"},
            "checkout_url": {"type": "string", "description": "The catalog's cart link for that variant"},
            "recommended": {"type": "boolean", "description": "Your recommendation (one)"},
            "why": {"type": "string", "description": "One line: why this one"},
        }, "required": ["title", "url", "price", "currency", "in_stock", "channel"]}},
    }, "required": ["options"]},
}
