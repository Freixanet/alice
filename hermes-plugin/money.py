"""Amounts as the code reads them: whole cents and an ISO currency, never free text.

Models write prices every way — «27,98 €», «€27.98», 27.98, «1.234,56 EUR», «$12» — and comparing
those as text went wrong: `same_amount` compared only the digits, so «27,98 €» and «2798 €» were
the same amount. Every price that enters the plugin is read here once; keys, totals and
comparisons use the cents. What cannot be read is None, never a guess.
"""

from __future__ import annotations

import re
from decimal import Decimal
from typing import Any, Optional, Tuple

SYMBOLS = {"€": "EUR", "$": "USD", "£": "GBP", "¥": "JPY"}
ZERO = {'JPY','KRW','VND','CLP','ISK','PYG','XOF','XAF','RWF','UGX','GNF','BIF','DJF','KMF','VUV','XPF'}
THREE = {'BHD','KWD','JOD','OMR','TND','IQD','LYD'}
CODES = re.compile(r"\b(EUR|USD|GBP|CHF|MXN|JPY|CAD|AUD|NZD|CNY|HKD|SGD|SEK|NOK|DKK|PLN|BRL|INR|KRW|VND|CLP|ISK|PYG|XOF|XAF|RWF|UGX|GNF|BIF|DJF|KMF|VUV|XPF|BHD|KWD|JOD|OMR|TND|IQD|LYD)\b", re.I)


def exponent(code):
    return 0 if code in ZERO else 3 if code in THREE else 2
NUMBER = re.compile(r"\d[\d.,\s  ']*")


def parse(value: Any, currency: str = "") -> Optional[Tuple[int, str]]:
    """(cents, currency) for a price, or None when there is no amount in it.

    One or two trailing digits are decimals; grouping separators must join groups of three.
    Reject conflicting currencies, negative/non-finite amounts and ambiguous text."""
    if isinstance(value, bool) or value is None:
        return None
    hint = str(currency or "").strip().upper()
    if hint and not re.fullmatch(r"[A-Z]{3}", hint):
        return None
    if isinstance(value, (int, float)):
        amount = Decimal(str(value))
        if not amount.is_finite() or amount < 0:
            return None
        amount *= 10 ** exponent(hint)
        return (int(amount), hint) if amount == amount.to_integral_value() else None
    text = str(value).strip()
    if not text:
        return None
    found = NUMBER.search(text)
    if not found:
        return None
    explicit = {SYMBOLS[s] for s in SYMBOLS if s in text}
    if '$' in text and hint in ('USD','CAD','AUD','NZD','MXN','HKD','SGD'):
        explicit.discard('USD');explicit.add(hint)
    if '¥' in text and hint=='CNY':
        explicit.discard('JPY');explicit.add(hint)
    explicit.update(code.upper() for code in CODES.findall(text))
    if len(explicit) > 1 or (explicit and hint and hint not in explicit):
        return None
    remainder = text[:found.start()] + text[found.end():]
    remainder = CODES.sub("", remainder)
    for symbol in SYMBOLS:
        remainder = remainder.replace(symbol, "")
    if remainder.strip():
        return None
    raw = found.group(0).strip()
    code = next(iter(explicit),hint)
    places = exponent(code)
    decimal = re.search(r"[.,](\d{1,"+str(places)+r"})$",raw) if places else None
    if decimal:
        whole = raw[: decimal.start()]
        fraction = decimal.group(1).ljust(places, "0")
    else:
        whole, fraction = raw, "0"
    if not re.fullmatch(r"\d+|\d{1,3}(?P<sep>[.,\s  '])\d{3}(?:(?P=sep)\d{3})*", whole):
        return None
    whole = re.sub(r"[.,\s  ']", "", whole)
    if not whole.isdigit():
        return None
    code = next(iter(explicit), hint)
    return int(whole) * (10 ** places) + int(fraction), code


def cents(value: Any, currency: str = "") -> Optional[int]:
    found = parse(value, currency)
    return found[0] if found else None


def same(a: Any, b: Any, currency: str = "") -> bool:
    """Two prices are the same amount in the same currency (a missing currency matches any)."""
    first, second = parse(a, currency), parse(b, currency)
    if not first or not second:
        return False
    if first[1] and second[1] and first[1] != second[1]:
        return False
    return first[0] == second[0]


def text(amount: int, currency: str) -> str:
    """Cents as a person reads them: 2798 EUR → «27,98 €», 2798 USD → «$27.98»."""
    currency = str(currency or "").upper()
    places=exponent(currency)
    whole, fraction = divmod(amount,10 ** places)
    if currency == "EUR" or not currency:
        grouped = f"{whole:,}".replace(",", ".") + f",{fraction:02d}"
        return grouped + (" €" if currency == "EUR" else "")
    symbol = {"USD": "$", "GBP": "£"}.get(currency)
    value = f"{whole:,}" + (f".{fraction:0{places}d}" if places else "")
    return f"{symbol}{value}" if symbol else f"{value} {currency}"
