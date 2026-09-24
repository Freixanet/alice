"""Payment cards the person gives Alice in a secure card, kept in Hermes' own vault.

Hermes fills a card into a checkout with ``browser_vault_fill`` — only on the site the
card is bound to, only after the person confirms, and without the agent ever seeing the
numbers. What it lacks is a way to *give* it a card from a phone: ``hermes vault add``
is a terminal wizard. So an agent that reaches a payment page with no card for it ends
its reply with ``[Añadir tarjeta](alice://connect/card?origin=…&profile=…)``; Alice shows
a native card form, and the dashboard route saves it here with Hermes' own vault store
(encrypted at rest, profile-scoped). A card saved for one site can be bound to another
site's payment page without typing it again (``bind``), which copies it inside the vault.

Nothing here logs or returns a card number, expiry or code: only the label ("Visa ···4242"),
the handle and the site it is bound to.
"""

from __future__ import annotations

import datetime as _dt
import re
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit

_DIGITS = re.compile(r"\D")
_BRANDS = (
    (re.compile(r"^4"), "Visa"),
    (re.compile(r"^(5[1-5]|2[2-7])"), "Mastercard"),
    (re.compile(r"^3[47]"), "American Express"),
    (re.compile(r"^(6011|65|64[4-9])"), "Discover"),
)


class CardError(ValueError):
    pass


def _store():
    from agent.vault_store import get_vault_store

    return get_vault_store()


def check_origin(origin: str) -> str:
    """An https site, as ``scheme://host[:port]``: the only place the card will be filled."""
    from agent.vault_store import normalize_origin

    raw = (origin or "").strip()
    parts = urlsplit(raw if "://" in raw else f"https://{raw}")
    if parts.scheme != "https" or not parts.hostname:
        raise CardError("A card is bound to a secure (https) payment page.")
    return normalize_origin(f"https://{parts.netloc}")


def twins(origin: str) -> List[str]:
    """The site with and without ``www.``: shops send checkouts to either, and it is the same site."""
    parts = urlsplit(origin)
    host, port = parts.hostname or "", f":{parts.port}" if parts.port else ""
    if host.startswith("www."):
        other = host[4:]
    elif host.count(".") == 1:
        other = f"www.{host}"
    else:
        return [origin]  # a subdomain such as sis.redsys.es has no www twin
    return [origin, f"https://{other}{port}"]


def luhn_ok(number: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(number)):
        d = int(ch)
        if i % 2:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def brand(number: str) -> str:
    return next((name for pattern, name in _BRANDS if pattern.match(number)), "Tarjeta")


def clean_card(fields: Dict[str, Any], today: Optional[_dt.date] = None) -> Dict[str, str]:
    """The vault payload (Hermes' own field names), or CardError saying what to fix."""
    number = _DIGITS.sub("", str(fields.get("card_number") or ""))
    if not 12 <= len(number) <= 19 or not luhn_ok(number):
        raise CardError("That card number is not valid.")
    try:
        month = int(str(fields.get("exp_month") or "").strip())
        year = int(str(fields.get("exp_year") or "").strip())
    except ValueError:
        raise CardError("The expiry date is not valid.") from None
    if year < 100:
        year += 2000
    today = today or _dt.date.today()
    if not 1 <= month <= 12 or (year, month) < (today.year, today.month) or year > today.year + 25:
        raise CardError("The expiry date is not valid.")
    cvc = _DIGITS.sub("", str(fields.get("cvc") or ""))
    if not 3 <= len(cvc) <= 4:
        raise CardError("The security code is 3 or 4 digits.")
    payload = {"card_number": number, "exp_month": f"{month:02d}", "exp_year": str(year), "cvc": cvc}
    name = " ".join(str(fields.get("cardholder_name") or "").split())[:80]
    if name:
        payload["cardholder_name"] = name
    postal = str(fields.get("billing_postal_code") or "").strip()[:16]
    if postal:
        payload["billing_postal_code"] = postal
    return payload


def _public(meta) -> Dict[str, Any]:
    return {"handle": meta.id, "label": meta.label, "origin": meta.origin}


def cards() -> List[Dict[str, Any]]:
    """Saved cards in this profile's vault: label, handle and bound site only."""
    return [_public(m) for m in _store().list_items() if m.kind == "payment"]


def save(origin: str, fields: Dict[str, Any]) -> Dict[str, Any]:
    site = check_origin(origin)
    payload = clean_card(fields)
    label = f"{brand(payload['card_number'])} ···{payload['card_number'][-4:]}"
    store = _store()
    saved = []
    for origin_ in twins(site):
        # The same card for the same site replaces the earlier one (a new expiry or code).
        for meta in store.list_items():
            if meta.kind == "payment" and meta.origin == origin_ and meta.label == label:
                store.remove_item(meta.id)
        saved.append(_public(store.add_item(kind="payment", label=label, secret=payload, origin=origin_)))
    return saved[0]


def bind(handle: str, origin: str) -> Dict[str, Any]:
    """Use a saved card on another payment page too, without it leaving the vault."""
    site = check_origin(origin)
    store = _store()
    meta = store.get_meta(str(handle or ""))
    if meta is None or meta.kind != "payment":
        raise CardError("That card is no longer saved.")
    secret = store.resolve_secret(meta.id)
    bound = []
    for origin_ in twins(site):
        existing = next((o for o in store.list_items()
                         if o.kind == "payment" and o.origin == origin_ and o.label == meta.label), None)
        bound.append(_public(existing) if existing else
                     _public(store.add_item(kind="payment", label=meta.label, secret=secret, origin=origin_)))
    return bound[0]


# Banks' and processors' own payment pages, where a shop sends the person to type their card.
# A saved card may be used there too (still only after the person's "Pagar" on Hermes' card).
PAYMENT_GATEWAYS = {
    "sis.redsys.es", "sis-t.redsys.es", "tpv.ceca.es", "pgw.ceca.es", "checkout.stripe.com",
    "hpp.addonpayments.com", "secure.worldpay.com", "live.adyen.com", "checkoutshopper-live.adyen.com",
    "pay.sumup.com", "secure.payu.com", "www.paygate.es",
}


def _host(origin: str) -> str:
    return urlsplit(origin or "").hostname or ""


def route_fill(handle: str, open_urls: List[str]) -> Optional[str]:
    """The payment item a fill should use, given the pages open in the browser, or None to leave
    the call as it is. A card saved for the shop is used on its www twin, and on the bank's payment
    page the shop sent the person to — never on any other site."""
    store = _store()
    meta = store.get_meta(str(handle or ""))
    if meta is None or meta.kind != "payment":
        return None
    open_origins = []
    for url in open_urls:
        parts = urlsplit(url or "")
        if parts.scheme == "https" and parts.hostname:
            open_origins.append(f"https://{parts.netloc}")
    same_card = [m for m in store.list_items() if m.kind == "payment" and m.label == meta.label]
    by_origin = {m.origin: m for m in same_card if m.origin}
    # 1. The bank's payment page is open: that is where the card goes.
    for origin in open_origins:
        if _host(origin) in PAYMENT_GATEWAYS:
            if origin in by_origin:
                chosen = by_origin[origin]
            else:
                chosen_public = bind(meta.id, origin)
                return chosen_public["handle"] if chosen_public["handle"] != meta.id else None
            return chosen.id if chosen.id != meta.id else None
    # 2. The shop's own checkout: the copy bound to the origin actually open (www or not).
    for origin in open_origins:
        if origin in by_origin and origin != meta.origin and origin in twins(meta.origin or origin):
            return by_origin[origin].id
    return None


def remove(handle: str) -> bool:
    """Removes the card from that site and from its www twin."""
    store = _store()
    meta = store.get_meta(str(handle or ""))
    if meta is None or meta.kind != "payment":
        return False
    sites = set(twins(meta.origin)) if meta.origin else set()
    for other in store.list_items():
        if other.kind == "payment" and other.label == meta.label and other.origin in sites and other.id != meta.id:
            store.remove_item(other.id)
    return bool(store.remove_item(meta.id))


def prompt(profile: str) -> str:
    """How an agent pays on a bank's page without a card number ever entering the chat."""
    return (
        "## Pagar con tarjeta\n"
        "La confirmación de Hermes para rellenar la tarjeta **es el sí de la compra**: no pidas otro sí "
        "en el chat antes ni después. Lleva la compra tú hasta la página donde se escribe la tarjeta "
        "(en muchas tiendas es la del banco, como `sis.redsys.es`, después de «Realizar pedido»; acepta "
        "las condiciones de la tienda como parte de la compra). Ahí escribe una sola línea con qué, "
        "cuánto, dónde llega y cuándo, llama a `browser_vault_list` y, si hay una tarjeta "
        "(`kind: payment`) con el `origin` de esa página, llama **una vez** a `browser_vault_fill`: "
        "Hermes le muestra a la persona «Pagar / Cancelar». Si acepta, pulsa el botón de pagar; si el "
        "banco pide aprobar en su app o un código, díselo y espera. Si cancela (`payment_declined`), "
        "no lo reintentes. Si una tienda cobra sin pasar por una página de tarjeta, pide ese único sí "
        "en el chat antes del clic que paga.\n"
        "Si no hay tarjeta para el `origin` exacto de la página donde están los campos de tarjeta, "
        "**no llames a `browser_vault_fill`** y nunca pidas los datos en el chat: termina con esta "
        "línea sola, con ese origen: "
        f"`[Añadir tarjeta](alice://connect/card?origin=ORIGEN&profile={profile})`. Si ya hay una "
        "tarjeta para otro sitio, la persona podrá usarla aquí con un toque. Si `browser_vault_fill` "
        "falla por `origin_mismatch`, no lo repitas: pide la tarjeta para el origen de la página actual. "
        "Si el relleno no encuentra los campos, dile que toque la vista en directo del navegador y la "
        "escriba desde ahí. Nunca escribas, repitas ni guardes números de tarjeta, caducidad o CVV en "
        "mensajes, notas, memoria o archivos."
    )
