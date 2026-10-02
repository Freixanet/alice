"""The invariants of a purchase, checked after every event the simulator records (qa/flows/purchase.yaml).

A finding is a dict: invariant, event, detail, plus the scenario and seed the simulator adds. The
oracle reads only what is durable or visible — the plugin's files, the errand as the app receives
it (`errands.public`), the ledger, the pages — never the simulator's own intentions, so it judges
the plugin and not the script that drives it.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

# Never written anywhere but the bank page's card fields (I3).
SECRETS = ("4000000000000002", "4000 0000 0000 0002", "FAKE-sim-password", "918273")
NOTHING_PAID = re.compile(r"no se ha (pagado|cobrado) nada|nothing was (paid|charged)", re.I)


class Oracle:
    def __init__(self, home: Path, errands, purchases, flow):
        self.home = Path(home)
        self.errands, self.purchases, self.flow = errands, purchases, flow
        self.findings: List[Dict[str, Any]] = []
        self.pays: Dict[str, int] = {}
        self.texts: List[str] = []

    def fail(self, invariant: str, event: str, detail: str) -> None:
        finding = {"invariant": invariant, "event": event, "detail": detail[:600]}
        if finding not in self.findings:
            self.findings.append(finding)

    # ── Checks made at a precise moment ──────────────────────────────────────────

    def before_pay(self, entry: Dict[str, Any], page_total: Optional[str], context: str, event: str) -> None:
        """A press that pays is about to happen: it must be the approved order at that total (I1), the
        first payment of that order (I2), and rest on evidence read in this browser context (I7)."""
        money = self.errands._money()
        checkout = self.errands.approved_checkout(entry)
        if checkout is None:
            self.fail("I1", event, f"pago ejecutado sin checkout aprobado vigente (estado {entry.get('status')}, "
                                   f"checkout {(entry.get('checkout') or {}).get('status')})")
        else:
            shown = money.parse(page_total, checkout.get("currency") or "") if page_total else None
            approved = (checkout.get("approved_cents"), checkout.get("approved_currency"))
            if shown is None or shown != approved:
                self.fail("I1", event, f"pago ejecutado con el total de la página {page_total!r} y aprobado {checkout.get('approved_total')!r}")
        evidence = entry.get("cart_evidence") or {}
        if evidence.get("context") != context:
            self.fail("I7", event, f"pago con evidencia de cesta de otro contexto ({evidence.get('context')!r} ≠ {context!r})")
        count = self.pays.get(entry["id"], 0) + 1
        self.pays[entry["id"]] = count
        if count > 1 and not entry.get("pay_again_until"):
            self.fail("I2", event, f"segundo pago ejecutado en el mismo recado ({count})")

    def saw_text(self, text: str, event: str) -> None:
        self.texts.append(str(text or ""))
        for secret in SECRETS:
            if secret in str(text or ""):
                self.fail("I3", event, f"un secreto aparece en un texto del agente o un resultado: {secret[:4]}…")

    # ── Checks after every event ─────────────────────────────────────────────────

    def after(self, event: str) -> None:
        self._secrets_on_disk(event)
        for entry in self.errands.listing(self.home):
            self._exit_and_honesty(entry, event)
        self._ledger(event)

    def _secrets_on_disk(self, event: str) -> None:
        for path in self.home.rglob("*"):
            if not path.is_file() or path.suffix in (".lock",) or path.stat().st_size > 2_000_000:
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for secret in SECRETS:
                if secret in text:
                    self.fail("I3", event, f"un secreto quedó escrito en {path.relative_to(self.home)}")

    def _exit_and_honesty(self, entry: Dict[str, Any], event: str) -> None:
        public = self.errands.public(entry)
        status = public.get("status")
        checkout = public.get("checkout") if isinstance(public.get("checkout"), dict) else {}
        receipt = public.get("receipt") if isinstance(public.get("receipt"), dict) else {}
        approved = checkout.get("status") == "approved"
        if status == "stuck":
            if not str(public.get("reason") or "").strip():
                self.fail("I5", event, f"recado {entry['id']} parado sin motivo")
            if approved and not receipt.get("outcome"):
                self.fail("I5", event, f"recado {entry['id']} parado tras aprobar sin resultado del pago (ni «unknown»)")
            if approved and NOTHING_PAID.search(str(public.get("reason") or "")):
                self.fail("I5", event, f"recado {entry['id']} dice que no se pagó tras una aprobación")
        if status == "done" and approved and not receipt.get("outcome"):
            self.fail("I5", event, f"recado {entry['id']} terminado tras aprobar sin resultado del pago")
        if status in ("needs_approval",) and not (checkout.get("status") == "pending" or public.get("approval")):
            self.fail("P1", event, f"recado {entry['id']} espera aprobación sin nada que aprobar")
        if status == "needs_input" and not ((public.get("questions") or {}).get("items")):
            self.fail("P1", event, f"recado {entry['id']} espera respuesta sin preguntas")

    def _ledger(self, event: str) -> None:
        try:
            entries = self.purchases._read(self.purchases._ledger(self.home))
        except Exception as exc:  # noqa: BLE001
            self.fail("I2", event, f"libro de pagos ilegible: {type(exc).__name__}")
            return
        paid: Dict[str, int] = {}
        for item in entries:
            if item.get("status") == "paid":
                key = f"{item.get('session')}|{item.get('order') or ''}"
                paid[key] = paid.get(key, 0) + 1
        for key, count in paid.items():
            if count > 1:
                self.fail("I2", event, f"el libro tiene {count} pagos del mismo pedido ({key})")

    # ── At the end of a scenario ─────────────────────────────────────────────────

    def cards_shown(self, session: str, event: str) -> None:
        sets = [s for s in self.flow._read(self.flow._path(self.home)) if s.get("session") == session]
        if not sets or not sets[-1].get("options"):
            self.fail("I6", event, "hay precio comprobado y no hay tarjetas para tocar")
