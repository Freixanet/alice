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

The shopping rules themselves live in ``skills/comprar/SKILL.md``.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import secrets
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from urllib.parse import urlsplit

WINDOW = 24 * 3600
# A second fill in the same conversation, shortly after, is the same payment filled again
# (the bank's form reloaded, a field came out empty) — not a second order.
REFILL = 30 * 60
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
        again = next((e for e in reversed(entries) if e.get("shop") == entry["shop"] and session
                      and e.get("session") == session and e.get("status") in ("pending", "unknown")
                      and now - float(e.get("at") or 0) < REFILL), None)
        if again is not None:
            # A refill of the same payment: one entry, still waiting for its outcome.
            again.update({"at": now, "status": "pending"})
            _write(path, entries)
            return again
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


def guard(home: Path, site: str, session: str = "", now: Optional[float] = None) -> Optional[Dict[str, str]]:
    """A pre_tool_call directive for a card fill on ``site``, or None to let it run."""
    now = now or time.time()
    name = shop(site)
    if not name:
        return None
    entries = [e for e in _read(_ledger(home))
               if e.get("shop") == name and now - float(e.get("at") or 0) < WINDOW]
    if not entries:
        return None
    open_ones = [e for e in entries if e.get("status") in ("pending", "unknown")]
    if (session and not any(e.get("status") == "paid" for e in entries) and open_ones
            and all(e.get("session") == session and now - float(e.get("at") or 0) < REFILL
                    for e in open_ones)):
        # The same payment, filled again before it was sent: Hermes' own «Pagar» still asks.
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


# What a shop's or bank's page says when a payment did not go through.
FAILURE = re.compile(
    r"(denegad[ao]|rechazad[ao]|no (ha sido |fue )?autorizad[ao]|no se ha podido (realizar|completar|procesar)"
    r"|error (en|durante) (el|la) (pago|operaci[oó]n|transacci[oó]n|compra)|pago (fallido|no realizado)"
    r"|fondos insuficientes|saldo insuficiente|tarjeta (caducada|bloqueada|no v[aá]lida)"
    r"|autenticaci[oó]n (fallida|no superada)|operaci[oó]n cancelada|SIS\d{4}"
    r"|payment (failed|declined|was declined|unsuccessful)|card (was )?declined|transaction (failed|declined)"
    r"|insufficient funds|authenticat\w+ failed)", re.IGNORECASE)
FOLLOW_UP = 10 * 60


def failure(text: Any) -> Optional[str]:
    """The words on the page that say the payment failed, or None."""
    found = FAILURE.search(str(text or ""))
    return found.group(0) if found else None


def open_payment(home: Path, session: str, now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """This conversation's payment still waiting for its outcome, within the hour."""
    now = now or time.time()
    for entry in reversed(_read(_ledger(home))):
        if (session and entry.get("session") == session and entry.get("status") in ("pending", "unknown")
                and now - float(entry.get("at") or 0) < 3600):
            return entry
    return None


def mark(home: Path, entry_id: str, **fields: Any) -> bool:
    """Sets fields on one entry; False if it was already set that way (said only once)."""
    with _locked(home) as path:
        entries = _read(path)
        entry = next((e for e in entries if e.get("id") == entry_id), None)
        if entry is None or all(entry.get(k) == v for k, v in fields.items()):
            return False
        entry.update(fields)
        _write(path, entries)
    return True


def error_note(home: Path, session: str, text: Any) -> Optional[str]:
    """What the agent is told when the page it just read says its payment failed; once per payment."""
    entry = open_payment(home, session)
    said = failure(text) if entry else None
    if not said or not mark(home, entry["id"], error_seen=True):
        return None
    return (f"\n\n[Alice] La página dice «{said}»: el pago en {entry['shop']} parece haber fallado. "
            "Díselo a la persona ahora, en una línea, con lo que dice la página y si se cobró o no "
            "(solo si lo ves), y registra `purchase_outcome` (declined si el banco lo rechazó, unknown "
            "si no está claro). No vuelvas a pagar sin que ella lo pida.")


def follow_up(home: Path, entry_id: str, now: Optional[float] = None) -> str:
    """Run by a one-off script ten minutes after a payment: a line for the person when it still has
    no known outcome, or nothing (a silent run)."""
    now = now or time.time()
    entry = next((e for e in _read(_ledger(home)) if e.get("id") == entry_id), None)
    if entry is None or entry.get("status") not in ("pending", "unknown") or entry.get("followed_up"):
        return ""
    mark(home, entry_id, followed_up=True)
    ago = _ago(now - float(entry.get("at") or now))
    return (f"⚠️ El pago con tarjeta en {entry['shop']} de hace {ago} no tiene un resultado confirmado: "
            "puede que haya fallado o que el banco espere tu aprobación en su app. Compruébalo en «Mis "
            "pedidos» de la tienda o en la app del banco antes de volver a pagar.")


def follow_up_script(plugin_dir: Path, home: Path, entry_id: str) -> str:
    """The body of the one-off check: it prints the notice, if any, and removes itself."""
    return (
        "import importlib.util, os, sys\n"
        f"spec = importlib.util.spec_from_file_location('alice_purchases_check', {str(Path(plugin_dir) / 'purchases.py')!r})\n"
        "module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)\n"
        f"line = module.follow_up(module.Path({str(home)!r}), {entry_id!r})\n"
        "if line:\n    print(line)\n"
        "try:\n    os.remove(__file__)\nexcept OSError:\n    pass\n"
    )


def run_tool(home: Path, args: Dict[str, Any]) -> Dict[str, Any]:
    return settle(home, str(args.get("site") or ""), str(args.get("outcome") or ""),
                  str(args.get("order") or ""), str(args.get("total") or ""))


SKILL = Path(__file__).resolve().parent / "skills" / "comprar" / "SKILL.md"


def prompt() -> str:
    """The shopping rules, read from ``skills/comprar/SKILL.md`` — the one place to audit and edit
    them — from its "## Comprar" heading on. If the file is missing, the payment rule still holds."""
    try:
        text = SKILL.read_text(encoding="utf-8")
        return text[text.index("## Comprar"):].strip()
    except (OSError, ValueError):
        return ("## Comprar\nDespués de pagar llama siempre a `purchase_outcome`; nunca pagues otra vez "
                "mientras no se sepa si el primer pago se cobró.")
