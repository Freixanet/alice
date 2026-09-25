"""One payment per order: a ledger the plugin keeps, so paying twice never depends on the model.

Every card Hermes fills after the person's «Pagar» is written down here (the shop, when, the
session). Before another card fill on the same shop:

* the earlier payment is still **unsettled** (nobody read how it ended) → the fill is blocked
  until the agent finds out and records it with ``purchase_outcome``. A timeout or a closed page
  after paying means "unknown", never "failed";
* it was **paid**, or its outcome stayed **unknown** → the fill goes through Hermes' approval
  card, which says so, and only the person's yes pays again;
* it was **declined** or **not charged** → nothing stands in the way.

Only facts about the purchase are kept: shop, time, outcome, order number and total as the
page showed them. Never card data. Entries older than a week are dropped.
"""
from __future__ import annotations

import fcntl
import json
import os
import secrets
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from urllib.parse import urlsplit

WINDOW = 24 * 3600
KEEP = 7 * 24 * 3600
OUTCOMES = ("paid", "declined", "not_charged", "unknown")

SCHEMA = {
    "name": "purchase_outcome",
    "description": (
        "Records how a card payment ended, read from the shop or bank page, the order email or the "
        "shop account: paid (with the order number), declined, not_charged or unknown. Call it after "
        "every payment. Until it is called, another card fill on that shop is refused."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "site": {"type": "string", "description": "The shop's address or domain, e.g. www.piensosraposo.es"},
            "outcome": {"type": "string", "enum": list(OUTCOMES)},
            "order": {"type": "string", "description": "Order number or confirmation text, when paid"},
            "total": {"type": "string", "description": "The total charged as the page showed it, e.g. 34,90 €"},
        },
        "required": ["site", "outcome"],
    },
}


def _ledger(home: Path) -> Path:
    return Path(home) / ".alice" / "purchases.json"


@contextmanager
def _locked(home: Path):
    path = _ledger(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(path) + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield path
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _read(path: Path) -> List[Dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def _write(path: Path, entries: List[Dict[str, Any]]) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".purchases.")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(entries, handle, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def shop(value: str) -> str:
    """The shop a URL or domain belongs to: its host without ``www.``."""
    text = str(value or "").strip().lower()
    host = urlsplit(text if "//" in text else "https://" + text).hostname or ""
    return host[4:] if host.startswith("www.") else host


def merchant(open_urls: Iterable[str], fill_origin: str, gateways: Iterable[str]) -> str:
    """Whose payment this is: the shop open next to the bank's page, else the page filled."""
    banks = set(gateways)
    for url in open_urls:
        parts = urlsplit(url or "")
        if parts.scheme == "https" and parts.hostname and parts.hostname not in banks:
            return shop(parts.hostname)
    return shop(fill_origin)


def record(home: Path, site: str, session: str = "", now: Optional[float] = None) -> Dict[str, Any]:
    now = now or time.time()
    entry = {"id": secrets.token_hex(6), "shop": shop(site), "at": now, "session": session,
             "status": "pending"}
    with _locked(home) as path:
        entries = [e for e in _read(path) if now - float(e.get("at") or 0) < KEEP]
        entries.append(entry)
        _write(path, entries)
    return entry


def settle(home: Path, site: str, outcome: str, order: str = "", total: str = "",
           now: Optional[float] = None) -> Dict[str, Any]:
    now = now or time.time()
    name = shop(site)
    if outcome not in OUTCOMES:
        return {"ok": False, "error": f"outcome must be one of {', '.join(OUTCOMES)}"}
    if not name:
        return {"ok": False, "error": "site is required"}
    with _locked(home) as path:
        entries = _read(path)
        recent = [e for e in entries if e.get("shop") == name and now - float(e.get("at") or 0) < WINDOW]
        if not recent:
            return {"ok": False, "error": f"no card payment recorded on {name} in the last 24 hours"}
        target = next((e for e in reversed(recent) if e.get("status") == "pending"), recent[-1])
        target.update({"status": outcome, "settled_at": now,
                       "order": str(order or "")[:120], "total": str(total or "")[:40]})
        _write(path, entries)
    return {"ok": True, "shop": name, "outcome": outcome}


def _ago(seconds: float) -> str:
    minutes = max(1, int(seconds // 60))
    return f"{minutes} min" if minutes < 90 else f"{round(minutes / 60)} h"


def guard(home: Path, site: str, now: Optional[float] = None) -> Optional[Dict[str, str]]:
    """A pre_tool_call directive for a card fill on ``site``, or None to let it run."""
    now = now or time.time()
    name = shop(site)
    if not name:
        return None
    entries = [e for e in _read(_ledger(home))
               if e.get("shop") == name and now - float(e.get("at") or 0) < WINDOW]
    if not entries:
        return None
    pending = [e for e in entries if e.get("status") == "pending"]
    if pending:
        ago = _ago(now - float(pending[-1]["at"]))
        return {"action": "block", "message": (
            f"Ya se envió un pago con tarjeta en {name} hace {ago} y nadie ha comprobado cómo acabó. "
            "No pagues otra vez: mira si se cobró (la página de confirmación, el correo del pedido, "
            "«Mis pedidos» en la tienda) y regístralo con `purchase_outcome`. Un error o un corte "
            "después de pagar es «unknown», no «declined».")}
    charged = [e for e in entries if e.get("status") in ("paid", "unknown")]
    if not charged:
        return None
    last = charged[-1]
    ago = _ago(now - float(last["at"]))
    said = (f"ya se pagó un pedido en {name} hace {ago}"
            + (f" (pedido {last['order']})" if last.get("order") else "")
            if last["status"] == "paid"
            else f"hace {ago} se envió un pago en {name} y no se sabe si se cobró")
    return {"action": "approve",
            "message": f"Atención: {said}. Aprueba solo si quieres pagar otra vez, en un pedido distinto.",
            # Unique: «permitir siempre» can never cover a later repeat payment.
            "rule_key": "alice-pay-again:" + secrets.token_hex(8)}


def run_tool(home: Path, args: Dict[str, Any]) -> Dict[str, Any]:
    return settle(home, str(args.get("site") or ""), str(args.get("outcome") or ""),
                  str(args.get("order") or ""), str(args.get("total") or ""))


def prompt() -> str:
    """How an agent shops: the right thing, the real total, the best code that works, one payment."""
    return (
        "## Comprar\n"
        "«Busca», «recomienda» o «prepara el carrito» es preparar, sin pagar. «Cómpralo» o «compra X "
        "hasta Y €» es la autorización: no pidas otro sí (Hermes ya pregunta al rellenar la tarjeta). "
        "Nunca inventes talla, compatibilidad, dirección ni presupuesto; si falta algo que cambia la "
        "compra, junta las dudas en un solo mensaje con tu propuesta.\n"
        "- **Elegir:** para un artículo exacto, comprueba modelo, variante, cantidad y estado; no lo "
        "cambies por uno parecido sin permiso. Para elegir, mira hasta tres opciones buenas y para "
        "cuando una cumple: no persigas céntimos. Precio, stock y entrega, en la tienda y para la "
        "dirección real; los comparadores son pistas.\n"
        "- **Total real:** producto + envío + comisiones + impuestos o aduanas + cambio de moneda. "
        "Si algo del total no se sabe o supera el límite, no pagues.\n"
        "- **Código de descuento:** antes de pagar, si la tienda tiene campo de cupón, busca en la web "
        "«<tienda> código descuento» y en la propia tienda (banner, página de ofertas). Prueba en el "
        "checkout hasta 5 códigos, de los más recientes a los más viejos, y quédate con el que más "
        "baje el **total**; si ninguno funciona, sigue sin él. Solo cuenta lo que el checkout aplica. "
        "No crees cuentas, no te suscribas a boletines, no instales extensiones y no salgas a webs "
        "de pago raras por un descuento. Di en una línea qué código ahorró cuánto.\n"
        "- **Carrito limpio:** no borres lo que la persona ya tenía; quita extras marcados de serie "
        "(seguro, garantía ampliada, donación, suscripción, prueba que se renueva, financiación).\n"
        "- **Un solo pago:** justo antes de pagar, vuelve a mirar producto, cantidad, dirección, total "
        "y que no haya ya un pedido igual. Después de pagar llama siempre a `purchase_outcome` con "
        "cómo acabó. Un corte, un error o una página cerrada después de pagar es «unknown»: "
        "compruébalo (confirmación, correo, «Mis pedidos») antes de hacer nada más, y nunca pagues "
        "otra vez ni cambies de tienda mientras no se sepa. Nunca digas «no se ha cobrado» sin verlo.\n"
        "- **Cierre:** «Pedido confirmado: qué, total, tienda, entrega prevista, número de pedido». "
        "Un cargo pendiente o un clic no es un pedido confirmado."
    )
