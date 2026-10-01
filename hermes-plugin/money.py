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
CODES = re.compile(r"\b(EUR|USD|GBP|CHF|MXN|JPY|CAD|AUD|SEK|NOK|DKK|PLN)\b", re.I)
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
        amount *= 100
        return (int(amount), hint) if amount == amount.to_integral_value() else None
    text = str(value).strip()
    if not text:
        return None
    found = NUMBER.search(text)
    if not found:
        return None
    explicit = {SYMBOLS[s] for s in SYMBOLS if s in text}
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
    decimal = re.search(r"[.,](\d{1,2})$", raw)
    if decimal:
        whole = raw[: decimal.start()]
        fraction = decimal.group(1).ljust(2, "0")
    else:
        whole, fraction = raw, "00"
    if not re.fullmatch(r"\d+|\d{1,3}(?P<sep>[.,\s  '])\d{3}(?:(?P=sep)\d{3})*", whole):
        return None
    whole = re.sub(r"[.,\s  ']", "", whole)
    if not whole.isdigit():
        return None
    code = next(iter(explicit), hint)
    return int(whole) * 100 + int(fraction), code


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
    whole, fraction = divmod(amount, 100)
    currency = str(currency or "").upper()
    if currency == "EUR" or not currency:
        grouped = f"{whole:,}".replace(",", ".") + f",{fraction:02d}"
        return grouped + (" €" if currency == "EUR" else "")
    symbol = {"USD": "$", "GBP": "£"}.get(currency)
    value = f"{whole:,}.{fraction:02d}"
    return f"{symbol}{value}" if symbol else f"{value} {currency}"
