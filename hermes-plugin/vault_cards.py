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


ALIAS_SEP = " · "


def identity(label: str) -> str:
    """The card itself, "Visa ···4242", whatever alias the person gave it."""
    return str(label or "").rsplit(ALIAS_SEP, 1)[-1]


def alias_of(label: str) -> str:
    text = str(label or "")
    return text.rsplit(ALIAS_SEP, 1)[0] if ALIAS_SEP in text else ""


def clean_alias(alias: Any) -> str:
    """A short name for the card ("Personal", "Empresa"): one line, 30 characters, never digits
    that could be taken for a card number."""
    text = " ".join(str(alias or "").replace(ALIAS_SEP.strip(), " ").split())[:30].strip()
    if sum(ch.isdigit() for ch in text) > 4:
        raise CardError("An alias can't hold a number like that.")
    return text


def _labelled(alias: str, card: str) -> str:
    return f"{alias}{ALIAS_SEP}{card}" if alias else card


def _public(meta) -> Dict[str, Any]:
    return {"handle": meta.id, "label": meta.label, "origin": meta.origin,
            "alias": alias_of(meta.label), "card": identity(meta.label)}


def cards() -> List[Dict[str, Any]]:
    """Saved cards in this profile's vault: label, handle and bound site only."""
    return [_public(m) for m in _store().list_items() if m.kind == "payment"]


def save(origin: Optional[str], fields: Dict[str, Any]) -> Dict[str, Any]:
    """Saves a card for one site, or, with no ``origin``, as a general card given from Settings.
    A general card is bound to no site, and Hermes refuses to fill it anywhere (``no_origin``)
    until ``bind`` ties a copy to the payment page it is wanted on."""
    if not (origin or "").strip():
        return _save_general(fields)
    site = check_origin(origin)
    alias = clean_alias(fields.get("alias"))
    payload = clean_card(fields)
    card = f"{brand(payload['card_number'])} ···{payload['card_number'][-4:]}"
    store = _store()
    # A card already saved elsewhere keeps its alias unless a new one is given.
    alias = alias or next((alias_of(m.label) for m in store.list_items()
                           if m.kind == "payment" and same_number(store, m, payload) and alias_of(m.label)), "")
    label = _labelled(alias, card)
    saved = []
    for origin_ in twins(site):
        # The same card for the same site replaces the earlier one (a new expiry or code).
        for meta in store.list_items():
            if meta.kind == "payment" and meta.origin == origin_ and same_number(store, meta, payload):
                store.remove_item(meta.id)
        saved.append(_public(store.add_item(kind="payment", label=label, secret=payload, origin=origin_)))
    return saved[0]


def _save_general(fields: Dict[str, Any]) -> Dict[str, Any]:
    alias = clean_alias(fields.get("alias"))
    payload = clean_card(fields)
    card = f"{brand(payload['card_number'])} ···{payload['card_number'][-4:]}"
    store = _store()
    alias = alias or next((alias_of(m.label) for m in store.list_items()
                           if m.kind == "payment" and same_number(store, m, payload) and alias_of(m.label)), "")
    for meta in store.list_items():
        if meta.kind == "payment" and not meta.origin and same_number(store, meta, payload):
            store.remove_item(meta.id)
    return _public(store.add_item(kind="payment", label=_labelled(alias, card), secret=payload))


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
                         if o.kind == "payment" and o.origin == origin_
                         and same_number(store, o, secret)), None)
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


def same_number(store, meta, payload):
    try:
        old = store.resolve_secret(meta.id)
        return bool(old.get('card_number')) and old['card_number'] == payload.get('card_number')
    except Exception:
        return False


def route_fill(handle: str, open_urls: List[str]) -> Optional[str]:
    """Compatibility symbol: never select a bank or card from unrelated global tabs."""
    return None


def rename(handle: str, alias: str) -> Dict[str, Any]:
    """Gives a card an alias (or clears it) on every site it is saved for. The vault has no
    update, so each copy is saved again under the new label and the old one removed."""
    store = _store()
    meta = store.get_meta(str(handle or ""))
    if meta is None or meta.kind != "payment":
        raise CardError("That card is no longer saved.")
    label = _labelled(clean_alias(alias), identity(meta.label))
    renamed = None
    for item in [m for m in store.list_items()
                 if m.kind == "payment" and same_number(store,m,store.resolve_secret(meta.id))]:
        if item.label == label:
            fresh = item
        else:
            fresh = store.add_item(kind="payment", label=label, secret=store.resolve_secret(item.id),
                                   origin=item.origin)
            store.remove_item(item.id)
        if item.id == meta.id:
            renamed = _public(fresh)
    return renamed


def remove(handle: str) -> bool:
    """Removes the card from that site and from its www twin."""
    store = _store()
    meta = store.get_meta(str(handle or ""))
    if meta is None or meta.kind != "payment":
        return False
    sites = set(twins(meta.origin)) if meta.origin else set()
    for other in store.list_items():
        if (other.kind == "payment" and same_number(store,other,store.resolve_secret(meta.id))
                and other.origin in sites and other.id != meta.id):
            store.remove_item(other.id)
    return bool(store.remove_item(meta.id))


def prompt(profile: str) -> str:
    """The deterministic controller owns the payment authority, not the prompt."""
    return (
        "## Pagar con tarjeta\n"
        "El pago necesita la aprobación del resumen completo en Alice. Usa purchase_action fill_card "
        "con el handle exacto aprobado y purchase_action click en el control observado. No uses "
        "browser_vault_fill ni el navegador global. La tienda y la pasarela comparten el mismo intento "
        "persistido antes de enviar. Tras un envío, comprueba su resultado con purchase_outcome; "
        "un fallo de red es unknown y nunca autoriza repetir el pago. Para un código, login_request "
        "kind vault.code dentro del mismo recado. Nunca pidas ni copies números de tarjeta o códigos al chat."
    )
