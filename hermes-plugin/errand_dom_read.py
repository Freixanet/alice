"""Constrained DOM inspection for Alice purchase errands.

The model supplies CSS selectors as *data*, never a JavaScript expression. This
tool resolves the HTTPS tab/context pinned to the errand and runs only a fixed
inspection template. It is not a replacement for an executor-level write gate.
"""
from __future__ import annotations

import json
import re
from typing import Any, Callable


MAX_SELECTORS = 8
MAX_SELECTOR = 160
MAX_MATCHES = 3
MAX_TEXT = 140  # 8 selectors × 3 matches remains below a small response budget
MAX_RESPONSE_BYTES = 4096
SENSITIVE = re.compile(
    r"(?:password|passwd|token|secret|otp|(?<![a-z])auth(?![a-z])|credit.?card|card.?number|"
    r"(?:^|[^a-z])cvv|(?:^|[^a-z])cvc|email|phone|address|"
    r"(?:^|[^a-z])cc-|(?<![a-z])(?:input|textarea|select|form|iframe|script|style)(?![a-z])|"
    r"contenteditable)", re.I,
)
EMAIL = re.compile(r"\b[^\s@]+@[^\s@]+\.[a-z]{2,}\b", re.I)
CARD_NUMBER = re.compile(r"\b(?:\d[ -]?){13,19}\b")

SCHEMA: dict[str, Any] = {
    "name": "errand_dom_read",
    "description": (
        "Read short, visible product names, prices and labels using CSS selectors "
        "in this errand's pinned HTTPS page. Selectors are data, never code. "
        "No scripts, expressions or form-input values. Do not select sections "
        "with account details, personal messages or secrets. Visible page text "
        "can still contain sensitive data. Use separate calls to act on the page."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "selectors": {"type": "array", "minItems": 1, "maxItems": MAX_SELECTORS,
                          "items": {"type": "string", "maxLength": MAX_SELECTOR}},
        },
        "required": ["selectors"],
        "additionalProperties": False,
    },
}


def _selectors(args: Any) -> list[str]:
    if not isinstance(args, dict) or set(args) != {"selectors"}:
        raise ValueError("Solo se permiten selectores CSS; no código ni propiedades adicionales.")
    items = args["selectors"]
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_SELECTORS:
        raise ValueError("Indica entre uno y ocho selectores CSS.")
    for item in items:
        if (not isinstance(item, str) or not 1 <= len(item) <= MAX_SELECTOR
                or any(ord(char) < 32 for char in item) or SENSITIVE.search(item)
                or ":has(" in item.lower()
                or re.search(r"(?:^|[\s,>+~])\*(?=$|[\s,>+~:.\[#])", item)
                or item.strip().lower() in ("*", "html", "body", ":root")):
            raise ValueError("Selector no permitido para una lectura limitada de productos.")
    return items


def _template(selectors: list[str]) -> str:
    # Serialized strings are inert operands for querySelectorAll, not script text.
    values = json.dumps(selectors, ensure_ascii=True)
    return """(()=>{
      'use strict';
      const selectors = %s;
      const restricted = 'input,textarea,select,form,iframe,script,style,[contenteditable],'
        +'[autocomplete],[type="password"],[name*="token" i],[name*="secret" i]';
      return selectors.map(selector => {
        const matches = [];
        try {
          const nodes = document.querySelectorAll(selector);
          for (let index = 0; index < Math.min(nodes.length,24); index++) {
            const el = nodes[index];
            if (matches.length >= %d) break;
            if (el.matches(restricted) || el.closest(restricted) || el.querySelector(restricted)) continue;
            if (!el.getClientRects().length || getComputedStyle(el).visibility === 'hidden') continue;
            // textContent includes hidden descendants and can reveal OTP/private
            // text. Never fall back to it when visible innerText is empty.
            const text = String(el.innerText || '').replace(/\\s+/g,' ').trim();
            if (text) matches.push({text: text.slice(0,%d)});
          }
        } catch (_) { return {selector, matches: [], error: 'invalid selector'}; }
        return {selector, matches};
      });
    })()""" % (values, MAX_MATCHES, MAX_TEXT)


def read(entry: Any, args: Any, *, inspect: Callable, evaluate: Callable) -> dict[str, Any]:
    selectors = _selectors(args)
    if not isinstance(entry, dict) or not entry.get("offer") or not entry.get("id"):
        raise ValueError("La lectura está limitada a un recado de compra elegido.")
    from urllib.parse import urlsplit
    page_origin, context, _ = inspect(entry)
    offer_url = str((entry.get("offer") or {}).get("url") or "")
    if (not offer_url.startswith("https://") or urlsplit(offer_url).hostname is None
            or page_origin != f"https://{urlsplit(offer_url).netloc.lower()}"):
        raise ValueError("La página no coincide con la tienda elegida.")
    if not isinstance(context, dict) or not context.get("target") or not context.get("context"):
        raise ValueError("No se pudo verificar la pestaña aislada del recado.")
    raw = evaluate(context, _template(selectors))
    # Do not return content if a page or browser context changed while reading.
    # This narrows (but cannot remove) the TOCTOU window; only the executor can
    # provide an atomic, final-action authority check.
    later_origin, later_context, _ = inspect(entry)
    if (later_origin != page_origin or not isinstance(later_context, dict)
            or later_context.get("target") != context["target"]
            or later_context.get("context") != context["context"]
            or later_context.get("url") != context.get("url")):
        raise ValueError("La pestaña o la tienda cambió durante la lectura.")
    if not isinstance(raw, list) or len(raw) != len(selectors):
        raise ValueError("La lectura de la página no devolvió un resultado verificable.")
    results = []
    for selector, row in zip(selectors, raw):
        if not isinstance(row, dict) or row.get("selector") != selector or not isinstance(row.get("matches"), list):
            raise ValueError("La lectura de la página ha cambiado.")
        if row.get("error"):
            raise ValueError("Un selector no es válido para esta página.")
        cleaned = []
        for item in row["matches"][:MAX_MATCHES]:
            if not isinstance(item, dict) or not isinstance(item.get("text"), str):
                continue
            content = " ".join(item["text"].split())[:MAX_TEXT]
            content = CARD_NUMBER.sub("[oculto]", EMAIL.sub("[oculto]", content))
            if content:
                cleaned.append({"text": content})
        results.append({"selector": selector, "matches": cleaned})
    output = {"ok": True, "results": results}
    if len(json.dumps(output, ensure_ascii=False).encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise ValueError("La lectura contiene demasiados datos; solicita menos selectores.")
    return output
