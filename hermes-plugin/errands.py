"""Errands: a task the person asks for runs on its own, apart from the chat.

A purchase used to be a goal on the chat's own session. Hermes judges that goal after every
turn of the chat, so an unrelated question later («dame los titulares») was followed by the
old purchase resuming in the same conversation, unannounced, as far as the payment page.

Now an errand has its own Hermes session (``errand-<id>``), driven here through the
gateway's ``/v1/runs``: a run, the goal judge on that session, the next run, until it is done,
stuck or needs the person. The chat only starts it (``errand_start``) and Alice shows it as a
card and in the list of errands.

Paying is never the model's call alone. Before the pay step the agent sends the checkout it
sees (``checkout_request``: shop, items, delivery, card, total) and the errand waits. Only the
person's «Permitir» in Alice approves it, for that shop and for ten minutes; until then a card
fill or a click that pays is refused (``pay_gate``), and Hermes' own card confirmation inside
the run is answered «once» only for an approved checkout, «deny» otherwise.

Signing in with a login saved in the vault needs no question, unless the person asked to be
asked (``ask_before_login``).
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import secrets
import tempfile
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional
from urllib.parse import urlsplit

SESSION_PREFIX = "errand-"
STATUSES = ("working", "needs_approval", "needs_input", "done", "stuck", "stopped", "denied")
ACTIVE = ("working", "needs_approval", "needs_input")
# An approved checkout pays within this window; later, the agent asks again.
APPROVAL_TTL = 10 * 60
KEEP = 30 * 24 * 3600
MAX_STEPS = 40
POLL_SECONDS = 1.5
# One errand: at most this many runs, whatever the judge says.
MAX_RUNS = 14
# A run with no event for this long has stalled (a model call that never returned): it is
# stopped and the errand goes on once; a second stall leaves it stuck.
STALL_SECONDS = 240
# The same chat asking again while its errand is starting gets that errand, not a second one.
DEDUPE_SECONDS = 10 * 60

CONTINUATION = "[Continuing toward your standing goal]"
APPROVED_PREFIX = "[checkout aprobado]"

# What a button that pays says, in the code or arguments of a browser action.
PAY_WORDS = re.compile(
    r"\b(pagar|pago ahora|realizar (el )?pedido|finalizar (la )?compra|confirmar (el )?pedido|confirmar y pagar"
    r"|comprar (ya|ahora)|tramitar pedido|place (your )?order|pay now|buy now|complete (purchase|order)"
    r"|confirm (and pay|purchase|order)|submit order)\b", re.I)
# A page where the next click can pay: the payment or review step of a checkout.
PAY_PAGE = re.compile(
    r"(/step/payment|/payment\b|/pago\b|/pay\b|/checkout/(review|confirm|payment|pago)|/confirmacion|/confirm\b"
    r"|onepage|/order-review|/revisar)", re.I)
# Browser actions that can press something on the page (Browser Use code or built-in tools).
CLICKS = re.compile(r"(click|submit|press|dispatchMouseEvent|dispatchKeyEvent|Enter|\.requestSubmit)", re.I)
BROWSER_ACTIONS = ("browser_exec", "browser_click", "browser_press", "browser_type")


# ── Store ───────────────────────────────────────────────────────────────────────


def _path(home: Path) -> Path:
    return Path(home) / ".alice" / "errands.json"


@contextmanager
def _locked(home: Path):
    path = _path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(path) + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield path
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _read(path: Path) -> List[Dict[str, Any]]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def _write(path: Path, entries: List[Dict[str, Any]]) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(Path(path).parent), prefix=".errands.")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(entries, handle, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def shop(value: str) -> str:
    """The shop a URL or domain belongs to: its host without ``www.``; "" for anything else."""
    text = str(value or "").strip().lower()
    try:
        host = urlsplit(text if "//" in text else "https://" + text).hostname or ""
    except ValueError:
        return ""
    if "." not in host or not re.fullmatch(r"[a-z0-9.-]+", host):
        return ""
    return host[4:] if host.startswith("www.") else host


def _clean(value: Any, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def create(home: Path, task: str, *, title: str = "", site: str = "", origin_session: str = "",
           profile: str = "", ask_before_login: bool = False, now: Optional[float] = None) -> Dict[str, Any]:
    now = now or time.time()
    task = _clean(task, 1500)
    if not task:
        raise ValueError("Say what the errand is.")
    errand_id = secrets.token_hex(5)
    entry = {
        "id": errand_id, "title": _clean(title, 80) or task[:80], "request": task, "site": shop(site),
        "status": "working", "session_id": SESSION_PREFIX + errand_id, "run_id": "", "runs": 0,
        "origin_session": _clean(origin_session, 120), "profile": _clean(profile, 64),
        "ask_before_login": bool(ask_before_login), "checkout": None, "receipt": None,
        "questions": None, "approval": None, "reason": "", "summary": "",
        "steps": [], "started_at": now, "updated_at": now,
    }
    with _locked(home) as path:
        entries = [e for e in _read(path) if e.get("status") in ACTIVE or now - float(e.get("updated_at") or 0) < KEEP]
        entries.append(entry)
        _write(path, entries)
    return entry


def get(home: Path, errand_id: str) -> Optional[Dict[str, Any]]:
    return next((e for e in _read(_path(home)) if e.get("id") == errand_id), None)


def listing(home: Path) -> List[Dict[str, Any]]:
    return sorted(_read(_path(home)), key=lambda e: float(e.get("updated_at") or 0), reverse=True)


def update(home: Path, errand_id: str, now: Optional[float] = None, **fields: Any) -> Optional[Dict[str, Any]]:
    with _locked(home) as path:
        entries = _read(path)
        entry = next((e for e in entries if e.get("id") == errand_id), None)
        if entry is None:
            return None
        entry.update(fields)
        entry["updated_at"] = now or time.time()
        _write(path, entries)
    return entry


def add_step(home: Path, errand_id: str, text: str, url: str = "", now: Optional[float] = None) -> None:
    text = _clean(text, 140)
    if not text:
        return
    with _locked(home) as path:
        entries = _read(path)
        entry = next((e for e in entries if e.get("id") == errand_id), None)
        if entry is None:
            return
        steps = entry.get("steps") or []
        if steps and steps[-1].get("text") == text:
            return
        steps.append({"text": text, "url": _clean(url, 300), "at": now or time.time()})
        entry["steps"] = steps[-MAX_STEPS:]
        entry["updated_at"] = now or time.time()
        if url and not entry.get("site"):
            entry["site"] = shop(url)
        _write(path, entries)


def of_session(home: Path, session_id: str) -> Optional[Dict[str, Any]]:
    """The errand a Hermes session belongs to, or None for any other session (a chat)."""
    session_id = str(session_id or "")
    if not session_id.startswith(SESSION_PREFIX):
        return None
    return get(home, session_id[len(SESSION_PREFIX):])


# ── Checkout ────────────────────────────────────────────────────────────────────

CHECKOUT_SCHEMA: Dict[str, Any] = {
    "name": "checkout_request",
    "description": (
        "Only inside an errand. Call it when the checkout is ready at the pay step and BEFORE filling a "
        "card or pressing the button that pays: it shows the person the checkout as the page shows it "
        "and waits for their «Permitir». Read every value from the page itself. Then end your turn; "
        f"the errand resumes with «{APPROVED_PREFIX}» when they approve. Without that approval a card fill "
        "or a pay click is refused."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "merchant": {"type": "string", "description": "The shop's name, e.g. 'HSN'"},
            "site": {"type": "string", "description": "The checkout page's address or domain"},
            "items": {
                "type": "array", "maxItems": 20,
                "items": {"type": "object", "properties": {
                    "name": {"type": "string"}, "variant": {"type": "string"},
                    "qty": {"type": "integer"}, "price": {"type": "string"},
                    "image": {"type": "string", "description": "The product image URL on the page"}},
                    "required": ["name"]},
            },
            "delivery": {"type": "string", "description": "Delivery as shown, e.g. 'Envío gratis · llega el viernes 2 oct'"},
            "address": {"type": "string", "description": "Where it is delivered, as shown"},
            "email": {"type": "string"},
            "card_label": {"type": "string", "description": "The saved card that will pay, e.g. 'Visa ···4242'"},
            "total": {"type": "string", "description": "The total to pay as the page shows it, e.g. '27,98 €'"},
            "currency": {"type": "string", "description": "ISO code, e.g. EUR"},
        },
        "required": ["merchant", "site", "items", "total"],
    },
}


def _items(raw: Any) -> List[Dict[str, Any]]:
    items = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, dict) or not _clean(item.get("name"), 120):
            continue
        try:
            qty = max(1, min(999, int(item.get("qty") or 1)))
        except (TypeError, ValueError):
            qty = 1
        image = _clean(item.get("image"), 500)
        items.append({"name": _clean(item.get("name"), 120), "variant": _clean(item.get("variant"), 80),
                      "qty": qty, "price": _clean(item.get("price"), 30),
                      "image": image if image.startswith("https://") else ""})
    return items[:20]


def request_checkout(home: Path, errand_id: str, args: Dict[str, Any], now: Optional[float] = None) -> Dict[str, Any]:
    now = now or time.time()
    entry = get(home, errand_id)
    if entry is None:
        return {"ok": False, "error": "This is not an errand; purchases are errands: use errand_start."}
    site = shop(args.get("site") or entry.get("site") or "")
    total = _clean(args.get("total"), 40)
    items = _items(args.get("items"))
    if not site or not total or not items:
        return {"ok": False, "error": "site, items and total are required, read from the checkout page."}
    checkout = {
        "id": secrets.token_hex(4), "status": "pending", "merchant": _clean(args.get("merchant"), 60) or site,
        "site": site, "items": items, "delivery": _clean(args.get("delivery"), 120),
        "address": _clean(args.get("address"), 160), "email": _clean(args.get("email"), 120),
        "card_label": _clean(args.get("card_label"), 60), "total": total,
        "currency": _clean(args.get("currency"), 8).upper(), "requested_at": now,
    }
    update(home, errand_id, now=now, status="needs_approval", checkout=checkout, site=entry.get("site") or site)
    return {"ok": True, "status": "needs_approval",
            "next": ("The person sees the checkout now. Do NOT fill a card or press anything that pays. "
                     "End your turn with one line saying the checkout is waiting for approval.")}


def decide_checkout(home: Path, errand_id: str, allow: bool, now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    now = now or time.time()
    entry = get(home, errand_id)
    checkout = (entry or {}).get("checkout")
    if entry is None or not isinstance(checkout, dict) or checkout.get("status") != "pending":
        return None
    checkout = {**checkout, "status": "approved" if allow else "denied", "decided_at": now}
    status = "working" if allow else "denied"
    return update(home, errand_id, now=now, checkout=checkout, status=status,
                  reason="" if allow else "Has denegado la compra.")


def approved_checkout(entry: Optional[Dict[str, Any]], site: str = "", now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """The errand's checkout the person approved, still fresh, for this shop (any shop when blank)."""
    now = now or time.time()
    checkout = (entry or {}).get("checkout")
    if not isinstance(checkout, dict) or checkout.get("status") != "approved":
        return None
    if now - float(checkout.get("decided_at") or 0) > APPROVAL_TTL:
        return None
    if site and shop(site) != checkout.get("site"):
        return None
    return checkout


# ── Gates (pre_tool_call) ───────────────────────────────────────────────────────


def _text_of(args: Any) -> str:
    if isinstance(args, dict):
        return " ".join(str(v) for v in args.values() if isinstance(v, (str, int, float)))
    return str(args or "")


def is_pay_action(tool_name: str, args: Any, active_url: str = "") -> bool:
    """A browser action that can pay: it names the pay button, or it presses something on a pay page."""
    if tool_name not in BROWSER_ACTIONS:
        return False
    text = _text_of(args)
    if PAY_WORDS.search(text):
        return True
    presses = tool_name in ("browser_click", "browser_press") or bool(CLICKS.search(text))
    return presses and bool(PAY_PAGE.search(str(active_url or "")))


def pay_gate(home: Path, session_id: str, *, card_fill_site: Optional[str] = None, tool_name: str = "",
             args: Any = None, active_url: str = "", gateways: Iterable[str] = (),
             merchant_site: str = "", now: Optional[float] = None) -> Optional[Dict[str, str]]:
    """A pre_tool_call directive that refuses paying without the person's approved checkout, or None.

    ``card_fill_site`` is the page a saved payment card is about to be written into (None when
    the call is not a card fill); otherwise the call is checked as a browser action."""
    filling = card_fill_site is not None
    if not filling and not is_pay_action(tool_name, args, active_url):
        return None
    entry = of_session(home, session_id)
    if entry is None:
        return {"action": "block", "message": (
            "Pagar desde una conversación no está permitido: las compras son recados. Llama a "
            "`errand_start` con lo que la persona pidió y di en una línea que lo pones en marcha.")}
    if filling:
        host = shop(card_fill_site or "")
        banks = {shop(g) for g in gateways}
        candidates = {host, shop(merchant_site)} - {""}
        fresh = approved_checkout(entry, now=now)
        ok = fresh is not None and (fresh.get("site") in candidates or host in banks)
    else:
        ok = approved_checkout(entry, now=now) is not None
    if ok:
        return None
    return {"action": "block", "message": (
        "No se paga sin la aprobación de la persona. Con el checkout listo en el paso de pago, llama a "
        "`checkout_request` con lo que muestra la página (tienda, artículos, entrega, tarjeta, total) y "
        f"termina tu turno; el recado sigue con «{APPROVED_PREFIX}» cuando la persona lo apruebe. "
        "Si ya se aprobó hace más de 10 minutos o en otra tienda, pide la aprobación otra vez.")}


def login_gate(home: Path, session_id: str) -> Optional[Dict[str, str]]:
    """A saved login is used without asking, unless the person asked to be asked first."""
    entry = of_session(home, session_id)
    if entry is None or not entry.get("ask_before_login"):
        return None
    return {"action": "approve",
            "message": f"El recado «{entry.get('title')}» quiere iniciar sesión con tu cuenta guardada. ¿Le dejas?",
            "rule_key": "alice-errand-login:" + secrets.token_hex(8)}


def is_payment_consent(approval: Optional[Dict[str, Any]]) -> bool:
    """Hermes' own «Fill payment card … on …» confirmation inside a run."""
    command = str((approval or {}).get("command") or "")
    return command.startswith("Fill payment card")


def consent_site(approval: Optional[Dict[str, Any]]) -> str:
    command = str((approval or {}).get("command") or "")
    found = re.search(r"\son\s+(\S+)\s*$", command)
    return found.group(1) if found else ""


# ── Questions ───────────────────────────────────────────────────────────────────


def ask(home: Path, errand_id: str, title: str, questions: List[Dict[str, Any]]) -> None:
    """ask_person inside an errand: the phone answers it from the errand, not from a chat."""
    update(home, errand_id, status="needs_input",
           questions={"title": _clean(title, 80), "items": questions[:10]})


def answer_text(answers: Dict[str, Any]) -> str:
    lines = []
    for key, value in (answers or {}).items():
        key = re.sub(r"[^A-Za-z0-9_.-]", "", str(key))[:40]
        if key:
            lines.append(f"[respuesta:{key}] {_clean(value, 400)}")
    return "\n".join(lines)


# ── Receipt ─────────────────────────────────────────────────────────────────────


def record_receipt(home: Path, session_id: str, args: Dict[str, Any], now: Optional[float] = None) -> None:
    """purchase_outcome inside an errand also writes its receipt."""
    entry = of_session(home, session_id)
    if entry is None:
        return
    checkout = entry.get("checkout") if isinstance(entry.get("checkout"), dict) else {}
    receipt = {
        "outcome": _clean(args.get("outcome"), 20), "order": _clean(args.get("order"), 120),
        "total": _clean(args.get("total"), 40) or checkout.get("total", ""),
        "merchant": checkout.get("merchant") or entry.get("site") or shop(args.get("site") or ""),
        "site": shop(args.get("site") or "") or checkout.get("site", ""),
        "items": _items(args.get("items")) or checkout.get("items") or [],
        "card_label": _clean(args.get("card_label"), 60) or checkout.get("card_label", ""),
        "delivery": checkout.get("delivery", ""), "at": now or time.time(),
    }
    update(home, entry["id"], now=now, receipt=receipt)


def outcome_properties() -> Dict[str, Any]:
    """The receipt fields purchase_outcome gains (purchases.SCHEMA)."""
    return {
        "items": CHECKOUT_SCHEMA["parameters"]["properties"]["items"],
        "card_label": {"type": "string", "description": "The card that paid, e.g. 'Visa ···4242'"},
    }


# ── The chat's tool ─────────────────────────────────────────────────────────────

START_SCHEMA: Dict[str, Any] = {
    "name": "errand_start",
    "description": (
        "Start an errand the person asked for — a purchase, an order, a booking, filling a basket or a "
        "form on a website. It runs on its own in the background, apart from this chat; Alice shows it "
        "as a card, asks the person to approve before anything is paid and tells them when it is done. "
        "Call it once, then answer in one short line that it is under way. Do not do the errand here."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "task": {"type": "string", "description": "What the person asked, in their words, with every detail that "
                                                      "matters (what, how many, size, where, when, price limit)."},
            "title": {"type": "string", "description": "A short title, e.g. 'Comprar Creapure 500 g en HSN'"},
            "site": {"type": "string", "description": "The shop or website, when known"},
            "ask_before_login": {"type": "boolean", "description": "Only when the person asked to be asked "
                                                                   "before signing in with their saved account."},
        },
        "required": ["task", "title"],
    },
}


def brief(entry: Dict[str, Any]) -> str:
    """The first message of an errand's session."""
    login = ("Antes de iniciar sesión, la persona quiere que se le pregunte: Hermes se lo pedirá."
             if entry.get("ask_before_login") else
             "Si la web pide iniciar sesión y hay un login guardado en el vault para ella, entra con "
             "`browser_vault_fill` sin preguntar.")
    return (
        f"[Recado de Alice] {entry['request']}\n\n"
        "Trabajas en segundo plano, fuera de cualquier chat: la persona no lee tus respuestas, ve la "
        "tarjeta del recado. Hazlo de principio a fin tú: nunca llames a `errand_start` (ya estás en el "
        "recado). El comentario `#` con que empieza cada paso del navegador es lo que la persona ve: "
        "escríbelo en su idioma y en pocas palabras («Añadir al carrito», «Elegir envío»). "
        f"{login} "
        "Para una duda que solo ella puede resolver (talla, sabor, una alternativa) usa `ask_person` y "
        "espera. Cuando el pedido esté listo en el paso de pago, NO rellenes la tarjeta ni pulses pagar: "
        "llama a `checkout_request` con lo que muestra la página (tienda, artículos con variante, "
        "cantidad, precio e imagen, entrega, dirección, email, tarjeta y total) y termina tu turno. "
        f"El recado seguirá con «{APPROVED_PREFIX}» si lo aprueba. Después de pagar, registra "
        "`purchase_outcome` con el número de pedido, el total, los artículos y la tarjeta. Termina "
        "cada turno con una sola línea que diga en qué punto estás."
    )


# ── Talking to the gateway ──────────────────────────────────────────────────────


def _env_value(path: Path, name: str) -> str:
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return ""


class Gateway:
    """The runs API of this Mac's Hermes gateway (loopback only; the key is never logged)."""

    def __init__(self, home: Path, profile: str = ""):
        env = Path(home) / ".env"
        host = _env_value(env, "API_SERVER_HOST") or "127.0.0.1"
        if host not in ("127.0.0.1", "localhost", "::1"):
            host = "127.0.0.1"
        port = _env_value(env, "API_SERVER_PORT") or "8642"
        prefix = f"/p/{profile}" if profile and profile != "default" else ""
        self.base = f"http://{host}:{port}{prefix}"
        key = ""
        if prefix:
            key = _env_value(Path(home) / "profiles" / profile / ".env", "API_SERVER_KEY")
        self._key = key or _env_value(env, "API_SERVER_KEY")

    def _call(self, method: str, path: str, body: Optional[Dict[str, Any]] = None, timeout: float = 15) -> Dict[str, Any]:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        if self._key:
            request.add_header("Authorization", f"Bearer {self._key}")
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 — loopback only
            raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else {}

    def start(self, session_id: str, text: str) -> str:
        out = self._call("POST", "/v1/runs", {"input": text, "session_id": session_id})
        run_id = str(out.get("run_id") or out.get("id") or "")
        if not run_id:
            raise RuntimeError("the gateway did not return a run id")
        return run_id

    def status(self, run_id: str) -> Dict[str, Any]:
        return self._call("GET", f"/v1/runs/{run_id}")

    def approve(self, run_id: str, choice: str, request_id: str = "") -> bool:
        body: Dict[str, Any] = {"choice": choice}
        if request_id:
            body["request_id"] = request_id
        try:
            return int(self._call("POST", f"/v1/runs/{run_id}/approval", body).get("resolved") or 0) > 0
        except urllib.error.HTTPError:
            return False

    def stop(self, run_id: str) -> None:
        try:
            self._call("POST", f"/v1/runs/{run_id}/stop", {})
        except Exception:
            pass


# ── Driving an errand ───────────────────────────────────────────────────────────

FINISHED = ("completed", "failed", "cancelled", "interrupted")


def _words(text: str) -> set:
    return set(re.findall(r"\w{3,}", str(text or "").lower()))


def repeats(before: str, now: str) -> bool:
    a, b = _words(before), _words(now)
    return bool(a) and len(b) >= 6 and len(a & b) / len(a | b) >= 0.6


def _goal_manager(session_id: str):
    from hermes_cli.goals import GoalManager

    return GoalManager(session_id=session_id)


def open_goal(entry: Dict[str, Any]) -> None:
    """The errand's own goal: judged on its session only, never on a chat's."""
    from hermes_cli.goals import GoalContract, GoalManager

    task_finish = _task_finish()
    contract = GoalContract(
        outcome=entry["request"],
        verification=("The order is placed and its confirmation (order number) was read back from the page, "
                      "or the checkout is waiting for the person's approval through checkout_request."),
        constraints=task_finish.CONSTRAINTS + (
            " In an errand, the person's yes to pay is ONLY their approval of checkout_request: "
            f"the errand resumes with «{APPROVED_PREFIX}». Hermes' card confirmation is not a yes."),
        stop_when=task_finish.STOP_WHEN)
    GoalManager(session_id=entry["session_id"], default_max_turns=task_finish.MAX_TURNS).set(
        entry["request"], max_turns=task_finish.MAX_TURNS, contract=contract)


def _task_finish():
    import importlib.util
    import sys

    name = "alice_task_finish"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "task_finish.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class Engine:
    """Drives one errand's runs until it is done, stuck or waiting for the person.

    Only one engine drives an errand at a time (a file lock per errand), whichever process
    started it; ``ensure_running`` starts one for an errand left working by a restart."""

    def __init__(self, home: Path, errand_id: str, *, gateway: Optional[Gateway] = None,
                 judge: Optional[Callable[[str, str], Dict[str, Any]]] = None,
                 sleep: Callable[[float], None] = time.sleep):
        self.home = Path(home)
        self.errand_id = errand_id
        entry = get(self.home, errand_id) or {}
        self.gateway = gateway or Gateway(self.home, entry.get("profile") or "")
        self.judge = judge or self._judge
        self.sleep = sleep

    # The goal judge on the errand's session; returns Hermes' decision dict.
    @staticmethod
    def _judge(session_id: str, reply: str) -> Dict[str, Any]:
        return _goal_manager(session_id).evaluate_after_turn(reply, user_initiated=False)

    def _entry(self) -> Dict[str, Any]:
        return get(self.home, self.errand_id) or {}

    @staticmethod
    def _waiting(entry: Dict[str, Any]) -> bool:
        try:
            return bool(_goal_manager(entry["session_id"]).is_waiting())
        except Exception:
            return False

    def _answer_approval(self, run_id: str, approval: Dict[str, Any]) -> None:
        entry = self._entry()
        request_id = str(approval.get("request_id") or approval.get("id") or "")
        if is_payment_consent(approval):
            ok = approved_checkout(entry) is not None
            self.gateway.approve(run_id, "once" if ok else "deny", request_id)
            return
        # Any other approval (a login the person wanted to be asked about, a repeat payment):
        # the person answers it from the errand.
        if (entry.get("approval") or {}).get("request_id") != request_id:
            update(self.home, self.errand_id, status="needs_approval",
                   approval={"run_id": run_id, "request_id": request_id,
                             "title": _clean(approval.get("description") or approval.get("command"), 300),
                             "command": _clean(approval.get("command"), 300),
                             "choices": [c for c in approval.get("choices") or ["once", "deny"] if c in ("once", "deny")]})

    def _wait_run(self, run_id: str) -> Dict[str, Any]:
        seen, since = None, time.time()
        while True:
            if self._entry().get("status") == "stopped":
                self.gateway.stop(run_id)
                return {"status": "cancelled"}
            try:
                state = self.gateway.status(run_id)
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    return {"status": "interrupted"}
                raise
            status = str(state.get("status") or "")
            mark = (state.get("updated_at"), state.get("last_event"), status)
            if mark != seen:
                seen, since = mark, time.time()
            elif status == "running" and time.time() - since > STALL_SECONDS:
                self.gateway.stop(run_id)
                return {"status": "stalled"}
            if status == "waiting_for_approval" and isinstance(state.get("approval"), dict):
                self._answer_approval(run_id, state["approval"])
            elif self._entry().get("approval") and status == "running":
                update(self.home, self.errand_id, approval=None, status="working")
            if status in FINISHED:
                return state
            self.sleep(POLL_SECONDS)

    def run(self, message: Optional[str] = None) -> str:
        """Runs until the errand leaves ``working``; returns its final status."""
        entry = self._entry()
        if not entry:
            return "missing"
        text = message or brief(entry)
        previous = ""
        stalls = 0
        while True:
            entry = self._entry()
            if entry.get("status") != "working":
                return entry.get("status", "missing")
            if int(entry.get("runs") or 0) >= MAX_RUNS:
                update(self.home, self.errand_id, status="stuck", reason="Ha usado todos sus intentos sin terminar.")
                return "stuck"
            try:
                run_id = self.gateway.start(entry["session_id"], text)
            except Exception as exc:  # noqa: BLE001
                update(self.home, self.errand_id, status="stuck",
                       reason=f"No se pudo hablar con Hermes: {type(exc).__name__}.")
                return "stuck"
            update(self.home, self.errand_id, run_id=run_id, runs=int(entry.get("runs") or 0) + 1)
            state = self._wait_run(run_id)
            reply = _clean(state.get("output") or "", 2000)
            entry = self._entry()
            if reply:
                update(self.home, self.errand_id, summary=reply[:300])
            if entry.get("status") != "working":
                return entry.get("status", "missing")
            if state.get("status") == "stalled":
                stalls += 1
                if stalls >= 2:
                    update(self.home, self.errand_id, status="stuck",
                           reason="El modelo dejó de responder dos veces seguidas.")
                    return "stuck"
                text = (CONTINUATION + " El paso anterior se quedó colgado: mira en qué punto está la "
                        "página y sigue desde ahí.")
                continue
            if state.get("status") == "failed":
                update(self.home, self.errand_id, status="stuck",
                       reason=_clean(state.get("error") or "El agente falló.", 200))
                return "stuck"
            receipt = entry.get("receipt") or {}
            if receipt.get("outcome") == "paid":
                update(self.home, self.errand_id, status="done")
                return "done"
            if previous and repeats(previous, reply):
                update(self.home, self.errand_id, status="stuck", reason="Repetía lo mismo sin avanzar.")
                return "stuck"
            previous = reply
            try:
                decision = self.judge(entry["session_id"], reply)
            except Exception:  # noqa: BLE001 — a judge that cannot answer lets the agent go on once
                decision = {"should_continue": True, "continuation_prompt": CONTINUATION}
            if decision.get("status") == "done":
                update(self.home, self.errand_id, status="done")
                return "done"
            if decision.get("should_continue"):
                text = decision.get("continuation_prompt") or CONTINUATION
                continue
            if decision.get("status") == "active":
                # Parked on a process or a deadline the agent set: wait it out without spending runs.
                deadline = time.time() + 45 * 60
                while time.time() < deadline and self._entry().get("status") == "working" and self._waiting(entry):
                    self.sleep(15)
                text = CONTINUATION
                continue
            update(self.home, self.errand_id, status="stuck",
                   reason=_clean(decision.get("reason") or decision.get("message") or "Se ha atascado.", 200))
            return "stuck"


_threads: Dict[str, threading.Thread] = {}
_threads_lock = threading.Lock()


def _engine_lock(home: Path, errand_id: str):
    folder = Path(home) / ".alice" / "errands"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(folder / f"{errand_id}.lock", "w")  # noqa: SIM115 — held by the engine thread
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def launch(home: Path, errand_id: str, message: Optional[str] = None,
           engine_factory: Optional[Callable[..., Engine]] = None) -> bool:
    """Starts the errand's engine in the background, unless one already drives it."""
    lock = _engine_lock(home, errand_id)
    if lock is None:
        return False

    def body():
        try:
            (engine_factory or Engine)(home, errand_id).run(message)
        except Exception as exc:  # noqa: BLE001 — never raised in a thread; the errand says what happened
            update(home, errand_id, status="stuck", reason=f"Error interno: {type(exc).__name__}.")
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
            lock.close()
            with _threads_lock:
                _threads.pop(errand_id, None)

    thread = threading.Thread(target=body, name=f"alice-errand-{errand_id}", daemon=True)
    with _threads_lock:
        _threads[errand_id] = thread
    thread.start()
    return True


def ensure_running(home: Path) -> List[str]:
    """After a restart: an errand still ``working`` whose engine is gone continues where it was."""
    started = []
    for entry in listing(home):
        if entry.get("status") == "working" and launch(
                home, entry["id"], "[Continuing toward your standing goal] Se reinició el servicio: "
                                   "comprueba en qué punto está el recado en el navegador y sigue."):
            started.append(entry["id"])
    return started


def start(home: Path, args: Dict[str, Any], *, origin_session: str = "", profile: str = "",
          now: Optional[float] = None) -> Dict[str, Any]:
    """``errand_start``: records the errand, opens its goal and starts it.

    Never from inside an errand (one started three copies of itself, all driving the same
    browser), and a chat that asks again while its errand is under way gets that one."""
    now = now or time.time()
    if str(origin_session or "").startswith(SESSION_PREFIX):
        return {"ok": False, "errand_id": origin_session[len(SESSION_PREFIX):], "status": "working",
                "error": "You are already inside this errand: do the task here, do not start another."}
    for other in listing(home):
        if (origin_session and other.get("origin_session") == origin_session and other.get("status") in ACTIVE
                and now - float(other.get("started_at") or 0) < DEDUPE_SECONDS):
            return {"errand_id": other["id"], "title": other["title"], "status": other["status"],
                    "next": "This errand is already under way; say so in one line. Do not start another."}
    entry = create(home, str(args.get("task") or ""), title=str(args.get("title") or ""),
                   site=str(args.get("site") or ""), origin_session=origin_session, profile=profile,
                   ask_before_login=bool(args.get("ask_before_login")))
    open_goal(entry)
    launch(home, entry["id"])
    return {"errand_id": entry["id"], "title": entry["title"], "status": entry["status"],
            "next": "Answer in one short line that it is under way; Alice shows its progress. Do not do it here."}


def resume(home: Path, errand_id: str, message: str) -> bool:
    """The person answered (approval, a question): the goal leaves its wait and the errand goes on."""
    entry = update(home, errand_id, status="working", questions=None, approval=None)
    if entry is None:
        return False
    try:
        manager = _goal_manager(entry["session_id"])
        if manager.state is not None and manager.state.status == "paused":
            manager.resume(reset_budget=False)
        else:
            manager.stop_waiting()
    except Exception:
        pass
    return launch(home, errand_id, message)


def stop(home: Path, errand_id: str) -> Optional[Dict[str, Any]]:
    entry = get(home, errand_id)
    if entry is None:
        return None
    if entry.get("status") not in ACTIVE:
        return entry
    entry = update(home, errand_id, status="stopped", reason="Lo paraste tú.")
    try:
        _goal_manager(entry["session_id"]).clear()
    except Exception:
        pass
    if entry.get("run_id"):
        Gateway(home, entry.get("profile") or "").stop(entry["run_id"])
    return entry


def public(entry: Dict[str, Any]) -> Dict[str, Any]:
    """What Alice shows: everything but the internal session wiring."""
    hidden = {"origin_session", "run_id"}
    out = {k: v for k, v in entry.items() if k not in hidden}
    if isinstance(out.get("approval"), dict):
        out["approval"] = {k: v for k, v in out["approval"].items() if k != "run_id"}
    return out


PROMPT = (
    "## Recados\n"
    "Una compra, un pedido, una reserva o llenar una cesta en una web es un recado: llama a "
    "`errand_start` **enseguida**, con lo que pidió la persona tal cual, y responde en una línea que lo "
    "pones en marcha. No abras el navegador ni hagas preguntas antes: el recado busca, pregunta lo que "
    "falte (talla, color, capacidad) y pide su aprobación antes de pagar, todo desde su tarjeta. Solo si "
    "la persona pide expresamente que se le pregunte antes de iniciar sesión, pasa "
    "`ask_before_login: true`. Cada recado vive en su tarjeta y en «Recados»: no hables de otros "
    "recados ni de compras anteriores salvo que te pregunte por ellos."
)

# A chat turn that asks for an errand: the chat may not browse or ask meanwhile (errand_turn).
ERRAND_REQUEST = re.compile(
    r"\b(c[oó]mpra(me|lo|la|los|las)?|comprar|p[ií]de(me|lo|la)?|pedir|res[eé]rva(me|lo|la)?|reservar"
    r"|carrito|cesta|a[nñ]ade\w*\s+al\s+carrito)\b", re.I)
TURN_NOTE = ("[Alice] Esto es un recado: llama a `errand_start` ahora con lo que pidió, y responde en una "
             "línea. No abras el navegador ni preguntes aquí: el recado lo hace y pregunta desde su tarjeta.")
def turn_note(started: Dict[str, Any]) -> str:
    """What the chat is told once the plugin has started (or found) the errand for this turn."""
    return (f"[Alice] Ya he puesto en marcha este recado (id {started.get('errand_id')}). Llama a "
            "`errand_start` con lo que pidió para que se vea su tarjeta y responde en una sola línea que "
            "está en marcha. No abras el navegador ni preguntes aquí, y no te fíes de lo que diga la "
            "conversación sobre recados anteriores: su estado real es este.")


TURN_BLOCK = ("Esta petición es un recado: no se navega ni se pregunta desde el chat. Llama a "
              "`errand_start` con lo que pidió la persona y responde en una línea que lo pones en marcha.")


def is_errand_request(text: Any) -> bool:
    text = " ".join(str(text or "").split())
    return bool(text) and not text.startswith(("[respuesta:", CONTINUATION)) and bool(ERRAND_REQUEST.search(text))
