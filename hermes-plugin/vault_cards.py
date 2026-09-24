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
    # The same card for the same site replaces the earlier one (a new expiry or code).
    for meta in store.list_items():
        if meta.kind == "payment" and meta.origin == site and meta.label == label:
            store.remove_item(meta.id)
    return _public(store.add_item(kind="payment", label=label, secret=payload, origin=site))


def bind(handle: str, origin: str) -> Dict[str, Any]:
    """Use a saved card on another payment page too, without it leaving the vault."""
    site = check_origin(origin)
    store = _store()
    meta = store.get_meta(str(handle or ""))
    if meta is None or meta.kind != "payment":
        raise CardError("That card is no longer saved.")
    for other in store.list_items():
        if other.kind == "payment" and other.origin == site and other.label == meta.label:
            return _public(other)
    secret = store.resolve_secret(meta.id)
    return _public(store.add_item(kind="payment", label=meta.label, secret=secret, origin=site))


def remove(handle: str) -> bool:
    store = _store()
    meta = store.get_meta(str(handle or ""))
    if meta is None or meta.kind != "payment":
        return False
    return bool(store.remove_item(meta.id))


def prompt(profile: str) -> str:
    """How an agent pays on a bank's page without a card number ever entering the chat."""
    return (
        "## Pagar con tarjeta\n"
        "Antes de pagar, deja la cesta exactamente como te la pidieron: si ya tenía ese producto (a "
        "menudo de un intento anterior), cambia la cantidad a la pedida y sigue, sin pararte a "
        "preguntar; si tiene otros productos, pregunta en una línea si los quitas. "
        "Cuando la persona ya ha dicho que sí a una compra y la página de pago (la del banco o la "
        "pasarela, como Redsys) pide la tarjeta: llama a `browser_vault_list`. Si hay una tarjeta "
        "(`kind: payment`) con el `origin` de esa página, rellénala con `browser_vault_fill`: Hermes "
        "le pide a la persona que lo confirme, y tú nunca ves los números. Luego pulsa el botón de "
        "pagar; si el banco pide aprobar en su app o un código, díselo y espera. "
        "Si no hay tarjeta para esa página, **nunca pidas los datos de la tarjeta en el chat**: "
        "di en una frase que falta la tarjeta y termina con esta línea sola: "
        f"`[Añadir tarjeta](alice://connect/card?origin=ORIGEN&profile={profile})`, con ORIGEN el "
        "origen de la página de pago (por ejemplo `https://sis.redsys.es`). Cuando diga que está, "
        "rellénala y paga. Si el relleno no encuentra los campos, dile que toque la vista en directo "
        "del navegador y la escriba desde ahí, y sigue cuando te lo diga. Nunca escribas, repitas ni "
        "guardes números de tarjeta, caducidad o CVV en mensajes, notas, memoria o archivos."
    )
