"""A purchase in the chat, before anything is bought: steps 1–6 of Alice's way of buying.

    1 search formats without assuming a variant or asking quantity
    2 the person's context: country, currency, shops and cards used before (`context_block`)
    3 search the Shop catalog (catalog.py) and the real shop, in parallel
    4 keep only what can be bought: a real https page, in stock, priced in their currency (`verify`)
    5 show the options as product cards, with a recommendation (`purchase_options`)
    6 the person taps one («[elección:<id>]») or says which in words

The price service may use isolated temporary carts; no personal cart or payment is touched. A browser
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
import unicodedata
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlsplit

KEEP = 3 * 24 * 3600
MAX_OPTIONS = 1000
CHANNELS = ("catalog", "browser")
CURRENCY = re.compile(r"^[A-Z]{3}$")
CHOICE = re.compile(r"^\s*(?:@[\w-]+\s+)?\[elecci[oó]n:([0-9a-f]{8}-[1-9][0-9]*)\]")
# A request to buy: the chat clarifies and shows options first; nothing starts on its own.
PURCHASE_REQUEST = re.compile(
    r"\b(c[oó]mpra(me|lo|la|los|las)?|comprar|p[ií]de(me|lo|la)?|pedir|carrito|cesta|a[nñ]ade\w*\s+al\s+carrito"
    r"|buy|order|purchase)\b", re.I)
# «Pídeme cita», «order a taxi», «pide hora»: an errand, not a purchase (nothing is bought in a
# shop), so it must be able to start from words.
NOT_A_PURCHASE = re.compile(
    r"\b(cita|hora|turno|mesa|taxi|cabify|uber|reserva\w*|appointment|booking|table|ride|cab|"
    r"consulta|visita|entrada|billete|ticket|vuelo|hotel|m[eé]dico|dentista)\b", re.I)
# What a button that fills a cart or goes to checkout says (the paying ones are errands.PAY_WORDS).
CART_WORDS = re.compile(
    r"(a[nñ]adir (a la cesta|al carrito)|add to (cart|bag|basket)|agregar al carrito|a la cesta|al carrito"
    r"|comprar ahora|buy now|checkout|tramitar|finalizar (la )?compra|proceed to|ir a (la )?caja|/cart/add)", re.I)
BROWSER_PRESSES = ("browser_exec", "browser_click", "browser_press", "browser_type")


def _money():
    """money.py beside this file (plugins load modules by path, not as a package)."""
    import importlib.util
    import sys as _sys

    name = "alice_money"
    if name not in _sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "money.py")
        module = importlib.util.module_from_spec(spec)
        _sys.modules[name] = module
        spec.loader.exec_module(module)
    return _sys.modules[name]


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


def remember_request(home: Path, session: str, request: str, now: Optional[float] = None) -> None:
    """Keep the person's purchase request across a gateway restart, scoped to its chat."""
    with _locked(home) as path:
        requests_path = path.with_name("purchase-requests.json")
        at = now or time.time()
        requests = [r for r in _read(requests_path)
                    if r.get("session") != session and at - float(r.get("at") or 0) < KEEP]
        requests.append({"session": session, "request": _clean(request, 1500), "at": at})
        _write(requests_path, requests)


def saved_request(home: Path, session: str, now: Optional[float] = None) -> str:
    at = now or time.time()
    for row in reversed(_read(_path(home).with_name("purchase-requests.json"))):
        if row.get("session") == session and at - float(row.get("at") or 0) < KEEP:
            return str(row.get("request") or "")
    return ""


def _normalized(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or "").casefold())
    return " ".join(re.sub(r"[^\w]+", " ", "".join(c for c in text if not unicodedata.combining(c))).split())


def requested_identity(request: str) -> Tuple[str, bool]:
    """Named brands/stores constrain options; explicitly requested alternatives relax it.

    Recognize 'marca/brand' and terminal 'de/en/from/by <name>' without a brand catalogue.
    More complex product requirements still need the agent's page verification.
    """
    request = re.sub(r"[,;]?\s+(?:no|sin|not|without)\s+(?:quiero\s+)?(?:otras?\s+marcas?|alternativas?|other brands?|alternatives?)\b.*$", "", request, flags=re.I)
    if re.search(r"otras? marcas?|alternativas?|other brands?|alternatives?", request, re.I):
        return "", False
    found = re.search(r'\b(marca|brand|de|en|from|by)\s+[«"\']?([\w&+.-]+(?:\s+[\w&+.-]+){0,2})[»"\']?[.!?]*\s*$', request, re.I)
    if not found:
        return "", False
    identity = _normalized(found.group(2).rstrip("."))
    # «de 1 litro», «de 500 g», «de color azul»: a size, an amount or a feature, never a brand or
    # a shop. Taking it for one once discarded every option as «no corresponde a 1 litro».
    if re.search(r"\d", identity) or re.search(
            r"^(color|talla|tama[nñ]o|sabor|size|flavou?r|colou?r|kilo|kilos|gramo|gramos|litro|litros|ml|cm|mm|"
            r"unidad|unidades|pack|caja|cajas|bote|botes|siempre|casa|regalo|hoy|ma[nñ]ana)\b", identity):
        return "", False
    return identity, found.group(1).casefold() == "en"


def matches_identity(option: Dict[str, Any], identity: str, store_only: bool) -> bool:
    hostname = urlsplit(str(option.get("url") or "")).hostname or ""
    values = [option.get("merchant"), hostname.replace(".", " ")]
    if not store_only:
        values += [option.get("brand"), option.get("title")]
    return any(re.search(r"(?<!\w)" + re.escape(identity) + r"(?!\w)", _normalized(v)) for v in values)


def set_key(options: Iterable[Dict[str, Any]]) -> str:
    """Shared with iOS: pages plus the variant, quantity, price and currency identify this offer.
    Repeating a search for another variant must not overwrite an earlier option's meaning."""
    # The app's rule exactly (`PurchaseOptionSet.key`): a field counts only when it is text, the
    # quantity only when it is a whole number (0 or absent is 1). A price sent as a number once
    # gave the two sides different keys, and the card said the options were gone.
    def text(value: Any) -> str:
        return value.strip() if isinstance(value, str) else ""

    def quantity(value: Any) -> str:
        if isinstance(value, float) and value.is_integer():
            value = int(value)  # JSON's 2.0 is the app's 2
        return str(value) if isinstance(value, int) and not isinstance(value, bool) and value != 0 else "1"

    rows = [[text(o.get("url")), text(o.get("variant")), quantity(o.get("qty")),
             text(o.get("price")), text(o.get("currency"))]
            for o in options if isinstance(o, dict)]
    encoded = json.dumps(rows, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:8]



# ── Country and currency: deduced, never asked ─────────────────────────────────

COUNTRY_NAMES = {
    "españa": "ES", "espana": "ES", "spain": "ES", "portugal": "PT", "francia": "FR", "france": "FR",
    "italia": "IT", "italy": "IT", "alemania": "DE", "germany": "DE", "andorra": "AD",
    "reino unido": "GB", "united kingdom": "GB", "uk": "GB", "inglaterra": "GB",
    "estados unidos": "US", "united states": "US", "usa": "US", "eeuu": "US", "méxico": "MX", "mexico": "MX",
}
CURRENCY_NAMES = {
    "euro": "EUR", "euros": "EUR", "€": "EUR", "dólar": "USD", "dolar": "USD", "dólares": "USD", "dollar": "USD",
    "$": "USD", "us$": "USD", "libra": "GBP", "libras": "GBP", "pound": "GBP", "£": "GBP", "peso": "MXN",
    "pesos": "MXN", "franco": "CHF", "franco suizo": "CHF",
}
ZONE_COUNTRY = {
    "Europe/Madrid": "ES", "Atlantic/Canary": "ES", "Africa/Ceuta": "ES", "Europe/Lisbon": "PT",
    "Europe/Paris": "FR", "Europe/Rome": "IT", "Europe/Berlin": "DE", "Europe/Andorra": "AD",
    "Europe/London": "GB", "America/Mexico_City": "MX",
}
EURO = {"ES", "PT", "FR", "IT", "DE", "AD", "IE", "NL", "BE", "AT", "FI", "GR", "LU"}
COUNTRY_CURRENCY = {"GB": "GBP", "US": "USD", "MX": "MXN", "CH": "CHF"}


def iso_country(value: Any) -> str:
    """«España», «spain» or «es» → «ES»; anything else unknown → ""."""
    text = " ".join(str(value or "").split()).lower()
    if not text:
        return ""
    if text in COUNTRY_NAMES:
        return COUNTRY_NAMES[text]
    return text.upper() if re.fullmatch(r"[a-z]{2}", text) else ""


def iso_currency(value: Any) -> str:
    """«Euro», «€» or «eur» → «EUR»; anything else unknown → ""."""
    text = " ".join(str(value or "").split()).lower()
    if not text:
        return ""
    if re.fullmatch(r"[a-z]{3}", text):
        return text.upper()
    return CURRENCY_NAMES.get(text, "")


def locale(details: Dict[str, str], timezone: str = "") -> Tuple[str, str]:
    """The person's country and currency: what they kept, else Hermes' own time zone. A person in
    Súria (08260, Barcelona) was asked «País de entrega» and «Moneda» before a creatine search."""
    country = iso_country(details.get("country")) or ZONE_COUNTRY.get(str(timezone or "").strip(), "")
    currency = iso_currency(details.get("currency")) or ("EUR" if country in EURO else COUNTRY_CURRENCY.get(country, ""))
    return country, currency


def verify(raw: Any, currency: str = "", picture: Optional[Callable[[str], str]] = None
           ) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    """Step 4: what can be bought, and what was left out and why. An option's id is its set's key
    and its position among those given, so the app and the plugin name it the same way."""
    options = [o for o in (raw if isinstance(raw, list) else []) if isinstance(o, dict)][:MAX_OPTIONS]
    key = set_key(options)
    expected = iso_currency(currency)
    kept: List[Dict[str, Any]] = []
    discarded: List[Dict[str, str]] = []
    for index, option in enumerate(options):
        title = _clean(option.get("title"), 160)
        url = str(option.get("url") or "").strip()
        price = _clean(option.get("price"), 40)
        money = iso_currency(option.get("currency")) or _clean(option.get("currency"), 8).upper()
        amount = _money().parse(option.get("price"), money)
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
        elif amount is None:
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
        # The price is read once, in cents, and written back the same way for every model.
        price_cents, read_currency = amount
        money = money or read_currency
        price = _money().text(price_cents, money)
        checkout_url = str(option.get("checkout_url") or "").strip()
        kept.append({
            "id": f"{key}-{index + 1}", "title": title, "merchant": _clean(option.get("merchant"), 80),
            "variant": _clean(option.get("variant"), 120), "qty": max(1, min(qty, 20)),
            "price": price, "price_cents": price_cents, "currency": money, "url": url, "image": image if image.startswith("https://") else "",
            "channel": channel, "catalog_id": _clean(option.get("catalog_id"), 120),
            "checkout_url": checkout_url if checkout_url.startswith("https://") else "",
            "recommended": bool(option.get("recommended")), "why": _clean(option.get("why"), 200),
        })
    # One recommendation exactly: the first the model marked, or the first card.
    marked = False
    for option in kept:
        option["recommended"] = option["recommended"] and not marked
        marked = marked or option["recommended"]
    if kept and not marked:
        kept[0]["recommended"] = True
    return kept, discarded


def _digits(value: Any) -> str:
    return re.sub(r"\D", "", str(value or ""))


def present(home: Path, session: str, args: Dict[str, Any], *, currency: str = "", now: Optional[float] = None,
            picture: Optional[Callable[[str], str]] = None, exact_item: bool = False,
            known_prices: Optional[Dict[str, str]] = None, request: str = "") -> Dict[str, Any]:
    """`purchase_options`: keeps the verified options for the app to draw and for the choice to find."""
    now = now or time.time()
    given = [o for o in ((args or {}).get("options") or []) if isinstance(o, dict)]
    requested = request or saved_request(home, session, now)
    identity, store_only = requested_identity(requested)
    # Generic searches offer a choice. A named brand/store or exact link may have only one match.
    if len(given) == 1 and not exact_item and not identity:
        return {"ok": False, "error": (
            "Enseña al menos dos opciones comprables, con tu recomendada marcada: otros formatos o tamaños "
            "de la tienda, o el mismo producto en otra tienda (`catalog_search`). La persona elige; tu "
            "preferencia va en `recommended` y `why`, no quitando las demás.")}
    kept, discarded = verify((args or {}).get("options"), currency, picture)
    # Creapure is the specified ingredient certification, not a synonym for
    # creatine. MicronPure from the same brand is still a substitution.
    if re.search(r'\bcreapure\b', requested, re.I) and not re.search(r'alternativas?|otras? marcas?', requested, re.I):
        matching = []
        for option in kept:
            if re.search(r'\bcreapure\b', option['title'], re.I):
                matching.append(option)
            else:
                discarded.append({'title': option['title'], 'why': 'no es Creapure, que pidió la persona'})
        kept = matching
    if identity:
        accepted = []
        for option in kept:
            index = int(option["id"].rsplit("-", 1)[1]) - 1
            if matches_identity(given[index], identity, store_only):
                accepted.append(option)
            else:
                discarded.append({"title": option["title"], "why": f"no corresponde a {identity}, que pidió la persona"})
        kept = accepted
    # A price the basket already contradicted is not offered again: the errand saw the real one.
    adjusted = []
    for option in list(kept):
        real = (known_prices or {}).get(option["url"].split("?")[0].rstrip("/"))
        if real and not _money().same(real, option["price"], option["currency"]):
            amount = _money().parse(real, option["currency"])
            if amount is None:
                discarded.append({"title": option["title"], "why": "el precio de la cesta no se pudo verificar en su moneda"})
                kept.remove(option)
                continue
            adjusted.append({"title": option["title"], "shown": option["price"], "real": real})
            option["price_cents"] = amount[0]
            option["price"] = _money().text(option["price_cents"], option["currency"])
    if not kept:
        # Kept empty for the app: its card draws nothing instead of saying the options are gone.
        key = set_key([o for o in ((args or {}).get("options") or []) if isinstance(o, dict)][:MAX_OPTIONS])
        with _locked(home) as path:
            sets = [x for x in _read(path) if now - float(x.get("at") or 0) < KEEP and x.get("key") != key]
            sets.append({"key": key, "session": _clean(session, 160), "options": [], "discarded": discarded,
                         "chosen": None, "at": now})
            _write(path, sets)
        return {"ok": False, "discarded": discarded, "error": (
            (f"No hay opciones válidas de {identity}; no ofrezcas otra marca o tienda sin que la persona lo pida. " if identity else "")
            + "Ninguna opción se pudo verificar como comprable. No enseñes nada: di en una línea qué ha "
            "fallado (sin stock, sin precio en su moneda…) y propón cómo seguir (otra tienda, otra "
            "variante, otro presupuesto).")}
    key = kept[0]["id"].split("-")[0]
    with _locked(home) as path:
        sets = [s for s in _read(path) if now - float(s.get("at") or 0) < KEEP and not (s.get("key") == key and s.get("session") == _clean(session, 160))]
        sets.append({"key": key, "session": _clean(session, 160), "options": kept, "chosen": None, "at": now,
                     "request": _clean(requested, 300)})
        _write(path, sets)
    return {"ok": True, "set": key, "options": [{"id": o["id"], "title": o["title"], "price": o["price"]}
                                                for o in kept],
            "discarded": discarded, "adjusted": adjusted,
            "next": ((f"Respeta {identity}: las opciones de otras marcas/tiendas se han descartado; no las ofrezcas en tu respuesta. " if identity else "")
                     + "La persona ve las tarjetas. Termina tu turno con una o dos líneas: la tarjeta marcada "
                     "«Recomendada» es «" + next(f"{o['title']} · {o['variant']} · {o['price']}".replace(" ·  · ", " · ")
                                                 for o in kept if o["recommended"]) + "»; recomienda esa y ninguna otra, "
                     "y di por qué. No preguntes nada más ni prepares la compra hasta que elija."
                     + (" Precios corregidos al que la tienda cobra en la cesta (ya lo vio un recado): "
                        + "; ".join(f"{a['title']} {a['real']}" for a in adjusted) + ". Usa esos."
                        if adjusted else ""))}


def sets_between(home: Path, session: str, since: float, until: Optional[float] = None,
                 now: Optional[float] = None) -> List[Dict[str, Any]]:
    """The option sets shown in a chat during one turn (by when they were shown), newest last: the
    app draws their cards under that turn's reply whether or not the model's call for them is in
    the transcript (it showed them itself, or it answered without calling anything)."""
    now = now or time.time()
    found = [s for s in _read(_path(home)) if s.get("session") == session and s.get("options")
             and now - float(s.get("at") or 0) < KEEP
             and float(s.get("at") or 0) >= float(since or 0)
             and (until is None or float(s.get("at") or 0) < float(until))]
    found.sort(key=lambda s: float(s.get("at") or 0))
    return [{"key": s["key"], "at": s["at"], "chosen": s.get("chosen"), "count": len(s["options"]),
             "aliases": list(s.get("aliases") or [])} for s in found]


def _words(text: Any) -> set:
    """The product words of a request, as six-letter stems: not the asking («compra», «quiero»)."""
    return {w[:6] for w in _normalized(text).split()
            if len(w) > 3 and not PURCHASE_REQUEST.search(w) and w not in ("quiero", "necesito", "puedes", "podrias", "porfa")}


def reshow(home: Path, session: str, request: str, now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """The person asks again for what was already searched and shown in this chat (nothing chosen):
    the same cards are shown again, now, instead of a new search or an answer from memory with no
    cards under it. The set is stamped with this moment so it lands under this turn's reply."""
    now = now or time.time()
    asked = _words(request)
    identity = requested_identity(request)
    if not asked:
        return None
    with _locked(home) as path:
        sets = _read(path)
        for found in sorted(sets, key=lambda s: -float(s.get("at") or 0)):
            if (found.get("session") != session or found.get("chosen") or not found.get("options")
                    or now - float(found.get("at") or 0) >= KEEP):
                continue
            words = _words(found.get("request") or "") or {w for o in found["options"] for w in _words(o.get("title"))}
            same_identity = not found.get("request") or requested_identity(found["request"]) == identity
            if asked & words and same_identity:
                found["at"] = now
                _write(path, sets)
                return found
    return None


def options_set(home: Path, key: str, session: Optional[str] = None,
                now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    now = now or time.time()
    matches = [s for s in _read(_path(home)) if (s.get("key") == key or key in (s.get("aliases") or []))
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


def choose(home: Path, session: str, option_id: str, now: Optional[float] = None, qty: int = 1, commit: bool = True) -> Optional[Dict[str, Any]]:
    """Step 6: the option, when it was shown in this chat; marked as the one chosen."""
    now = now or time.time()
    key = str(option_id or "").split("-")[0]
    with _locked(home) as path:
        sets = _read(path)
        found = next((s for s in sets if (s.get("key") == key or key in (s.get("aliases") or [])) and s.get("session") == session
                      and now - float(s.get("at") or 0) < KEEP), None)
        picked = next((o for o in (found or {}).get("options") or [] if o.get("id") == option_id), None)
        if picked is None:
            return None
        if not isinstance(qty, int) or isinstance(qty, bool) or not 1 <= qty <= 20:
            raise ValueError("La cantidad debe estar entre 1 y 20.")
        picked = {**picked, "qty": qty}
        if commit:
            found["chosen"] = option_id
            found["phase"] = "chosen"
            found["chosen_qty"] = qty
            _write(path, sets)
    return picked


def chosen_id(text: Any) -> Optional[str]:
    found = CHOICE.match(str(text or ""))
    return found.group(1) if found else None


def is_purchase_request(text: Any) -> bool:
    text = " ".join(str(text or "").split())
    return bool(text) and not text.startswith(("[respuesta:", "[elecci", "[Continuing")) \
        and bool(PURCHASE_REQUEST.search(text)) and not NOT_A_PURCHASE.search(text)


def is_cart_action(tool_name: str, args: Any) -> bool:
    """A browser action that puts something in a cart or heads to checkout: the errand's, never the chat's."""
    if tool_name not in BROWSER_PRESSES:
        return False
    text = " ".join(str(v) for v in args.values()) if isinstance(args, dict) else str(args or "")
    return bool(CART_WORDS.search(text))


# ── What the errand is given ───────────────────────────────────────────────────


def offer(chosen: Dict[str, Any]) -> Dict[str, Any]:
    """The chosen option as the errand keeps it: exactly what to buy, where and for how much."""
    keys = ("title", "merchant", "variant", "qty", "price", "currency", "url", "checkout_url", "channel", "catalog_id", "quote_ref", "verified_at", "shipping", "condition")
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


def context_block(details: Dict[str, str], cards: List[Dict[str, Any]], recent: List[Dict[str, Any]],
                  timezone: str = "") -> str:
    """What the chat knows before searching. Card labels only, never numbers. Nothing here is asked."""
    country, currency = locale(details, timezone)
    where = ", ".join(v for v in (details.get("city"), details.get("postcode")) if v)
    shops = []
    for entry in recent:
        name = entry.get("merchant") or entry.get("site")
        if name and name not in shops:
            shops.append(name)
    last_card = next((e.get("card_label") for e in recent if e.get("card_label")), "")
    labels = [c.get("label") for c in cards if c.get("label")]
    lines = [
        f"país: {country or 'el de la tienda'}", f"moneda: {currency or 'la de la tienda'}",
        f"envío a: {where or 'sin dirección guardada'}",
        f"tiendas donde ya compró: {', '.join(shops[:5]) or 'ninguna todavía'}",
        f"tarjetas guardadas: {', '.join(labels) or 'ninguna'}" + (f" (la última usada: {last_card})" if last_card else ""),
    ]
    return ("[Alice · compra] Lo que sé de la persona — " + "; ".join(lines)
            + ". No le preguntes país ni moneda: son estos.")


def turn_note(block: str) -> str:
    return (block + " Sigue «Comprar»: nunca ofrezcas una opción que no hayas visto; si lo que falta depende de lo que "
            "vende la tienda (formato, talla, sabor), mira primero la tienda (`catalog_search` solo dice dónde se "
            "vende; sus resultados no se pueden enseñar como tarjetas) y "
            "enseña lo comprable como tarjetas con `purchase_options`, no como preguntas. En el chat no se llena "
            "ningún carrito ni se paga. Una portada o una ficha de otro producto no demuestra que el solicitado no exista. "
            "No declares falta de disponibilidad ni propongas sustituciones desde una búsqueda parcial: revisa la "
            "categoría y registra todos los formatos con purchase_discover. Una comprobación fallida es un problema "
            "de verificación, no falta de stock.")


def chosen_note(started: Dict[str, Any], chosen: Dict[str, Any]) -> str:
    return (f"[Alice] La persona ha elegido «{chosen['title']}» ({chosen.get('variant') or 'sin variante'}, "
            f"{chosen['price']}, {chosen.get('merchant') or 'la tienda'}). Ya he puesto en marcha la compra "
            f"(id {started.get('errand_id')}). Llama a `errand_start` con `option_id` {chosen['id']} para que se "
            "vea su tarjeta y responde en una sola línea que la preparas y que le enseñarás el total antes de "
            "pagar. No abras el navegador aquí.")


PRICED = re.compile(r"\d[\d.,]*\s*(€|eur\b|\$|usd\b|£)|(€|\$|£)\s*\d", re.I)


def ask_refusal(questions: Iterable[Dict[str, Any]], looked: bool) -> Optional[str]:
    """Why an ask_person during a purchase must not reach the person, or None."""
    questions = [q for q in questions if isinstance(q, dict)]
    if any(str(q.get("field") or "") in ("country", "currency") for q in questions):
        return ("No preguntes país ni moneda: Alice ya te los ha dado en el contexto de la compra. Si falta alguno, "
                "usa el de la tienda.")
    if any(re.search(r"cuánt[oa]s?|cantidad|unidades|botes|how many|quantity|units", str(q.get("question") or "") + " " + str(q.get("field") or ""), re.I) for q in questions):
        return "La cantidad se elige en el detalle del formato, inicialmente 1. No la preguntes antes de que la persona elija el producto."
    choices = [str(c) for q in questions for c in (q.get("choices") or [])]
    if choices and any(PRICED.search(c) for c in choices):
        return ("Productos con precio no se eligen en una pregunta: enséñalos como tarjetas con `purchase_options` "
                "(página, stock y precio verificados) y la persona toca uno.")
    if choices and not looked:
        return ("Aún no has mirado la tienda ni el catálogo: no ofrezcas opciones que no has visto. Busca primero "
                "(`catalog_search`, la ficha de la tienda) y pregunta solo entre lo que existe de verdad; lo que "
                "solo sabe la persona y no depende de la tienda, pregúntalo sin opciones.")
    if choices and any(re.search(r'formato|talla|sabor|marca|producto|alternativa|sustitu|te vale|solo encuentro|sólo encuentro|no (?:hay|encuentro)', str(q.get('question') or ''), re.I) for q in questions):
        return ('Los productos y formatos se presentan con purchase_discover, purchase_verify y purchase_options, '
                'no mediante preguntas de sustitución o formato. Mantén la marca y el producto pedidos; una ficha '
                'o portada parcial no demuestra que no existan. Revisa la categoría completa.')
    return None


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
        "listed in `discarded`. Then end your turn: the person taps one and the purchase starts by itself "
        "(words such as «la segunda» do not choose; if they answer in words, ask them to tap the card)."
    ),
    "parameters": {"type": "object", "properties": {
        "search_id": {"type": "string", "description": "Inventory returned by purchase_discover; all formats must be quoted or discarded"},
        "options": {"type": "array", "maxItems": MAX_OPTIONS, "items": {"type": "object", "properties": {
            "quote_ref": {"type": "string", "description": "Trusted purchase_verify quote id. Required; a model-written amount is not evidence."},
            "title": {"type": "string", "description": "The product's name as the shop gives it"},
            "merchant": {"type": "string", "description": "The shop, e.g. 'HSN'"},
            "variant": {"type": "string", "description": "Size, colour, capacity… exactly as it will be bought"},
            "qty": {"type": "integer"},
            "price": {"type": "string", "description": "What the shop charges for this exact variant, e.g. "
                                                     "'27,98 €' — not a conditional discount (code, app, first order)"},
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
        }, "required": ["quote_ref", "title", "url", "price", "currency", "in_stock", "channel"]}},
    }, "required": ["search_id", "options"]},
}
