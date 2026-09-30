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
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlsplit

SESSION_PREFIX = "errand-"
STATUSES = ("working", "needs_approval", "needs_input", "needs_card", "done", "stuck", "stopped", "denied")
ACTIVE = ("working", "needs_approval", "needs_input", "needs_card")
# An approved checkout pays within this window; later, the agent asks again.
APPROVAL_TTL = 10 * 60
# A checkout waiting longer than this is stale (shops close their checkout sessions; prices
# and delivery move): it can no longer be approved, only prepared again.
CHECKOUT_TTL = 15 * 60
KEEP = 30 * 24 * 3600
MAX_STEPS = 40
POLL_SECONDS = 1.5
# One errand: at most this many runs, whatever the judge says.
MAX_RUNS = 14
# A run with no event for this long has stalled (a model call that never returned): it is
# stopped and the errand goes on once; a second stall leaves it stuck.
STALL_SECONDS = 240
# Going round in circles on one page (a form the shop keeps rejecting): this many steps on
# the same page over this long, and the errand stops and says so instead of trying forever.
CIRCLE_STEPS = 12
CIRCLE_SECONDS = 240

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


def _new_entry(task: str, *, title: str = "", site: str = "", origin_session: str = "",
               profile: str = "", ask_before_login: bool = False, now: float,
               offer: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    task = _clean(task, 1500)
    if not task:
        raise ValueError("Say what the errand is.")
    errand_id = secrets.token_hex(5)
    return {
        "id": errand_id, "title": _clean(title, 80) or task[:80], "request": task, "site": shop(site),
        "status": "working", "session_id": SESSION_PREFIX + errand_id, "run_id": "", "runs": 0,
        "origin_session": _clean(origin_session, 120), "profile": _clean(profile, 64),
        "ask_before_login": bool(ask_before_login), "checkout": None, "receipt": None,
        "questions": None, "approval": None, "reason": "", "summary": "",
        "steps": [], "started_at": now, "updated_at": now,
        # The option the person chose in the chat (purchase_flow.offer): what exactly to buy.
        "offer": offer or None,
    }


def create(home: Path, task: str, *, title: str = "", site: str = "", origin_session: str = "",
           profile: str = "", ask_before_login: bool = False, now: Optional[float] = None,
           offer: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    now = now or time.time()
    entry = _new_entry(task, title=title, site=site, origin_session=origin_session,
                       profile=profile, ask_before_login=ask_before_login, now=now, offer=offer)
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
                    "image": {"type": "string", "description": "The product picture's exact src, read from the "
                                                           "page (document.querySelector), never guessed"}},
                    "required": ["name"]},
            },
            "delivery": {"type": "string", "description": "Delivery as shown, e.g. 'Envío gratis · llega el viernes 2 oct'"},
            "address": {"type": "string", "description": "Where it is delivered, as shown"},
            "email": {"type": "string"},
            "card_label": {"type": "string", "description": "The saved card that will pay, e.g. 'Visa ···4242', "
                                                         "or empty: the person chooses it when approving"},
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


USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
              "Version/18.0 Safari/605.1.15")
OG_IMAGE = re.compile(
    r"""<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image)["'][^>]*content=["']([^"']+)["']"""
    r"""|<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image)["']""",
    re.I)


def _fetch(url: str, limit: int, accept: str) -> Tuple[bytes, str]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    with urllib.request.urlopen(request, timeout=6) as response:  # noqa: S310 — https only, checked by callers
        return response.read(limit), str(response.headers.get("Content-Type") or "")


def is_picture(url: str, fetch: Callable[..., Tuple[bytes, str]] = _fetch) -> bool:
    """Whether an address really serves a picture (an agent once named one that answered 404)."""
    if not str(url or "").startswith("https://"):
        return False
    try:
        data, kind = fetch(url, 64_000, "image/*")
    except Exception:  # noqa: BLE001 — unreachable is not a picture
        return False
    return kind.lower().startswith("image/") and len(data) > 200


def page_picture(page: str, fetch: Callable[..., Tuple[bytes, str]] = _fetch) -> str:
    """The product page's own picture (its og:image), or ""."""
    if not str(page or "").startswith("https://"):
        return ""
    try:
        data, _ = fetch(page, 400_000, "text/html")
    except Exception:  # noqa: BLE001
        return ""
    found = OG_IMAGE.search(data.decode("utf-8", "replace"))
    if not found:
        return ""
    address = (found.group(1) or found.group(2) or "").replace("&amp;", "&")
    return address if address.startswith("https://") else ""


def product_pages(entry: Dict[str, Any]) -> List[str]:
    """The pages the errand looked at before the basket and checkout, newest first."""
    pages: List[str] = []
    for step in reversed(entry.get("steps") or []):
        url = str(step.get("url") or "")
        low = url.lower()
        if not url.startswith("https://") or any(k in low for k in ("checkout", "/bag", "/cart", "carrito", "cesta",
                                                                     "signin", "login", "payment", "pago")):
            continue
        base = url.split("#")[0]
        if base not in pages:
            pages.append(base)
    return pages[:3]


def real_pictures(entry: Dict[str, Any], items: List[Dict[str, Any]],
                  fetch: Callable[..., Tuple[bytes, str]] = _fetch) -> List[Dict[str, Any]]:
    """Every item's picture checked from the Mac; one that does not load is replaced by the
    product page's own picture, or left out rather than shown as a broken placeholder."""
    fallback: Optional[str] = None
    for item in items:
        if item.get("image") and is_picture(item["image"], fetch):
            continue
        if fallback is None:
            fallback = next((found for page in product_pages(entry)
                             if (found := page_picture(page, fetch)) and is_picture(found, fetch)), "")
        item["image"] = fallback
    return items


def paying_card(home: Path, site: str, labels: List[str], asked: str = "") -> str:
    """The card the checkout starts with: the one the agent read, else the only saved one, else the one
    the person paid with last (at this shop first). Empty when that is not clear: the person picks."""
    labels = [label for label in labels if label]
    if asked and (not labels or asked in labels):
        return asked
    if len(labels) == 1:
        return labels[0]
    paid = [e for e in listing(home) if isinstance(e.get("receipt"), dict) and e["receipt"].get("card_label")]
    for entry in sorted(paid, key=lambda e: (e["receipt"].get("site") != site, -float(e.get("updated_at") or 0))):
        if entry["receipt"]["card_label"] in labels:
            return entry["receipt"]["card_label"]
    return ""


def request_checkout(home: Path, errand_id: str, args: Dict[str, Any], now: Optional[float] = None,
                     fetch: Optional[Callable[..., Tuple[bytes, str]]] = None,
                     saved_cards: Optional[Callable[[], List[Dict[str, Any]]]] = None) -> Dict[str, Any]:
    now = now or time.time()
    entry = get(home, errand_id)
    if entry is None:
        return {"ok": False, "error": "This is not an errand; purchases are errands: use errand_start."}
    site = shop(args.get("site") or entry.get("site") or "")
    total = _clean(args.get("total"), 40)
    items = _items(args.get("items"))
    if not site or not total or not items:
        return {"ok": False, "error": "site, items and total are required, read from the checkout page."}
    # Step 8: a way to pay before the person sees the total. With no saved card the person is asked
    # for one first; the errand resumes with «[tarjeta lista]» and calls checkout_request again.
    labels: List[str] = []
    if saved_cards is not None:
        try:
            labels = [str(c.get("label") or "") for c in saved_cards()]
        except Exception:  # noqa: BLE001 — the vault unreadable is not "no card": the person chooses
            labels = ["?"]
        if not [label for label in labels if label]:
            update(home, errand_id, now=now, status="needs_card", card_origin=f"https://{site}")
            return {"ok": True, "status": "needs_card",
                    "next": ("There is no saved card to pay with: the person is asked to add one first. Do not "
                             "pay. End your turn with one line saying you wait for the card.")}
    items = real_pictures(entry, items, fetch or _fetch)
    checkout = {
        "id": secrets.token_hex(4), "status": "pending", "merchant": _clean(args.get("merchant"), 60) or site,
        "site": site, "items": items, "delivery": _clean(args.get("delivery"), 120),
        "address": _clean(args.get("address"), 160), "email": _clean(args.get("email"), 120),
        "card_label": paying_card(home, site, [label for label in labels if label != "?"],
                                  _clean(args.get("card_label"), 60)),
        "total": total, "currency": _clean(args.get("currency"), 8).upper(), "requested_at": now,
    }
    update(home, errand_id, now=now, status="needs_approval", checkout=checkout, site=entry.get("site") or site)
    return {"ok": True, "status": "needs_approval",
            "next": ("The person sees the checkout now. Do NOT fill a card or press anything that pays. "
                     "End your turn with one line saying the checkout is waiting for approval.")}


def expire_checkouts(home: Path, now: Optional[float] = None) -> List[str]:
    """Checkouts left waiting past CHECKOUT_TTL become «expired»: approving one resumed an errand
    on a checkout Apple had closed hours before, without the person knowing."""
    now = now or time.time()
    expired = []
    for entry in listing(home):
        checkout = entry.get("checkout")
        if (isinstance(checkout, dict) and checkout.get("status") == "pending"
                and now - float(checkout.get("requested_at") or now) > CHECKOUT_TTL):
            update(home, entry["id"], now=now, checkout={**checkout, "status": "expired"})
            expired.append(entry["id"])
    return expired


def refresh_message(checkout: Dict[str, Any]) -> str:
    return (f"[checkout caducado] El checkout de {checkout.get('merchant') or checkout.get('site')} esperó demasiado y "
            "ya no vale. Vuelve a la tienda, comprueba que el pedido sigue igual (artículos, precio, envío), llega "
            "otra vez al paso de pago y llama a `checkout_request` con lo que muestre la página ahora. No pagues.")


def decide_checkout(home: Path, errand_id: str, allow: bool, now: Optional[float] = None,
                    card_label: str = "") -> Optional[Dict[str, Any]]:
    now = now or time.time()
    expire_checkouts(home, now)
    entry = get(home, errand_id)
    checkout = (entry or {}).get("checkout")
    if entry is None or not isinstance(checkout, dict) or checkout.get("status") != "pending":
        return None
    checkout = {**checkout, "status": "approved" if allow else "denied", "decided_at": now}
    if allow:
        # The yes is to this total: the errand pays only if the page still shows it (approved_message).
        checkout["approved_total"] = checkout.get("total", "")
    if allow and _clean(card_label, 60):
        checkout["card_label"] = _clean(card_label, 60)
    status = "working" if allow else "denied"
    return update(home, errand_id, now=now, checkout=checkout, status=status,
                  reason="" if allow else "Has denegado la compra.")


def approved_message(checkout: Dict[str, Any]) -> str:
    """How the errand goes on after «Permitir»: pay that total, with that card, and nothing else."""
    total = checkout.get("approved_total") or checkout.get("total") or ""
    card = f" ({checkout['card_label']})" if checkout.get("card_label") else ""
    return (
        f"{APPROVED_PREFIX} La persona ha aprobado pagar {total} en {checkout.get('merchant') or checkout.get('site')}. "
        f"Justo antes de pulsar pagar, mira el total de la página: si es exactamente {total}, paga con la "
        f"tarjeta guardada{card}; si es otro, NO pagues y vuelve a llamar a `checkout_request` con lo que "
        "muestra ahora. Después de pagar, registra `purchase_outcome` con el número de pedido, el total, "
        "los artículos, la tarjeta y la entrega prevista.")


def same_amount(a: Any, b: Any) -> bool:
    """«27,98 €» and «EUR 27.98» are the same amount: only the digits are compared."""
    digits = lambda value: re.sub(r"\D", "", str(value or ""))  # noqa: E731
    return bool(digits(a)) and digits(a) == digits(b)


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

# Asked inside an errand and refused: the agent decides these itself (a salutation, a newsletter),
# or they have their own card (paying).
TRIVIAL = re.compile(
    r"(tratamiento|t[ií]tulo de cortes[ií]a|\bsr\.?\b|\bsra\.?\b|se[ñn]or|\bmr\b|\bmrs\b|\bms\b|salutation"
    r"|newsletter|bolet[ií]n|publicidad|comunicaciones comerciales|ofertas por correo|prefijo|marketing)", re.I)
CARD_QUESTION = re.compile(r"(tarjeta|\bcard\b|m[eé]todo de pago|forma de pago|payment|\bcvv\b|\bpagar con\b)", re.I)


def vet_questions(questions: List[Dict[str, Any]]) -> Optional[str]:
    """Why these questions must not reach the person from an errand, or None."""
    text = " ".join(f"{q.get('question', '')} {' '.join(q.get('choices') or [])}" for q in questions)
    if CARD_QUESTION.search(text):
        return ("Do not ask about cards or how to pay. If the payment page needs a card, call "
                "`card_request` with that page's address: Alice shows the person their saved cards or a "
                "form to add one, and the errand resumes when it is ready.")
    if TRIVIAL.search(text):
        return ("Do not ask this: choose it yourself (a salutation, a newsletter, a prefix: the "
                "neutral or default option, or none). Ask only what changes what is bought, where it "
                "goes or what it costs, all in one go.")
    return None


def ask(home: Path, errand_id: str, title: str, questions: List[Dict[str, Any]]) -> None:
    """ask_person inside an errand: the phone answers it from the errand, not from a chat."""
    update(home, errand_id, status="needs_input",
           questions={"title": _clean(title, 80), "items": questions[:10]})


# ── Cards ───────────────────────────────────────────────────────────────────────

CARD_SCHEMA: Dict[str, Any] = {
    "name": "card_request",
    "description": (
        "Only inside an errand. Call it when the payment page needs a card and `browser_vault_list` has "
        "none for that page's origin. Alice shows the person their saved cards or a form to add one, "
        "bound to that page; end your turn, and the errand resumes when the card is ready. Never ask "
        "about cards with ask_person."
    ),
    "parameters": {
        "type": "object",
        "properties": {"page": {"type": "string", "description": "The address of the page with the card fields"}},
        "required": ["page"],
    },
}


def request_card(home: Path, errand_id: str, page: str) -> Dict[str, Any]:
    parts = urlsplit(str(page or ""))
    if parts.scheme != "https" or not parts.hostname:
        return {"ok": False, "error": "page must be the https address of the page with the card fields"}
    origin = f"https://{parts.hostname}" + (f":{parts.port}" if parts.port else "")
    update(home, errand_id, status="needs_card", card_origin=origin)
    return {"ok": True, "status": "needs_card",
            "next": "The person sees their cards now. End your turn with one line saying you wait for the card."}


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
        "delivery": _clean(args.get("delivery"), 160) or checkout.get("delivery", ""), "at": now or time.time(),
    }
    # Paid something other than the total the person approved: said on the result, never smoothed over.
    approved = checkout.get("approved_total")
    if approved and receipt["total"] and not same_amount(approved, receipt["total"]):
        receipt["approved_total"] = approved
    update(home, entry["id"], now=now, receipt=receipt)


def outcome_properties() -> Dict[str, Any]:
    """The receipt fields purchase_outcome gains (purchases.SCHEMA)."""
    return {
        "items": CHECKOUT_SCHEMA["parameters"]["properties"]["items"],
        "card_label": {"type": "string", "description": "The card that paid, e.g. 'Visa ···4242'"},
        "delivery": {"type": "string", "description": "When it arrives, as the confirmation says"},
    }


# ── The chat's tool ─────────────────────────────────────────────────────────────

START_SCHEMA: Dict[str, Any] = {
    "name": "errand_start",
    "description": (
        "Start an errand in the background, apart from this chat; Alice shows it as a card, asks the "
        "person to approve before anything is paid and tells them how it ended. A PURCHASE starts only "
        "from the option the person chose among those shown with `purchase_options`: pass its "
        "`option_id` (the plugin carries its page, variant, quantity and price). Anything else — a "
        "booking, a form on a website — passes `task` and `title`. Call it once, then answer in one "
        "short line. Do not do the errand here."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "option_id": {"type": "string", "description": "A purchase: the chosen option's id, e.g. 'a1b2c3d4-2'"},
            "task": {"type": "string", "description": "Not a purchase: what the person asked, in their words, with "
                                                      "every detail that matters (what, where, when, limit)."},
            "title": {"type": "string", "description": "A short title, e.g. 'Reservar la ITV'"},
            "site": {"type": "string", "description": "The website, when known"},
            "ask_before_login": {"type": "boolean", "description": "Only when the person asked to be asked "
                                                                   "before signing in with their saved account."},
        },
    },
}

# The errand's reply when the chosen option cannot be bought as chosen: it stops there.
BLOCKED = re.compile(r"^\s*(BLOQUEADO|BLOCKED)\s*:\s*", re.I)


PRICE = re.compile(r"(\d[\d.]*,\d{2}\s*€|€\s*\d[\d.,]*|\d[\d,]*\.\d{2}\s*(?:€|EUR|USD|\$)|\$\s*\d[\d.,]*)")


GONE = re.compile(r"(agotad|sin stock|no (est[aá] )?disponible|out of stock|unavailable|ya no (se )?vende|no existe"
                  r"|descatalogad|discontinued)", re.I)


def blocked_by(said: str) -> Dict[str, Any]:
    """What stopped the chosen option: another price (the person may accept it), the option gone, or
    anything else — which is the agent's to fix, not the person's."""
    if re.search(r"\b(precio|price|cuesta|cobra)\b", said, re.I):
        found = PRICE.search(said)
        if found:
            return {"kind": "price", "price": " ".join(found.group(1).split())}
    if GONE.search(said):
        return {"kind": "gone"}
    return {"kind": "other"}


def basket_prices(home: Path, now: Optional[float] = None, within: float = 7 * 24 * 3600) -> Dict[str, str]:
    """The price a basket showed for a product page, from purchases stopped on it lately (newest wins)."""
    now = now or time.time()
    prices: Dict[str, str] = {}
    for entry in sorted(listing(home), key=lambda e: float(e.get("updated_at") or 0)):
        blocked, offer = entry.get("blocked"), entry.get("offer")
        if (isinstance(blocked, dict) and blocked.get("kind") == "price" and blocked.get("price")
                and isinstance(offer, dict) and offer.get("url") and now - float(entry.get("updated_at") or 0) < within):
            prices[str(offer["url"]).split("?")[0].rstrip("/")] = blocked["price"]
    return prices


def go_on(home: Path, errand_id: str, accept_price: bool = False) -> Optional[Dict[str, Any]]:
    """The person's way on from a stopped purchase: the same option at the shop's price, or a retry.
    Nothing is paid by this: the errand goes back to the checkout and asks for that exact total."""
    entry = get(home, errand_id)
    if entry is None or entry.get("status") != "stuck":
        return None
    blocked = entry.get("blocked") if isinstance(entry.get("blocked"), dict) else {}
    offer = entry.get("offer") if isinstance(entry.get("offer"), dict) else None
    if accept_price:
        if blocked.get("kind") != "price" or not blocked.get("price"):
            return None
        price = blocked["price"]
        if offer:
            offer = {**offer, "price": price}
        update(home, errand_id, offer=offer, blocked=None, reason="")
        message = (f"[precio aceptado] La persona acepta la misma opción a {price}. Sigue con el carrito hasta "
                   "el paso de pago y llama a `checkout_request` con el total exacto; ese total es el que aprobará. "
                   "No pagues antes.")
    else:
        update(home, errand_id, blocked=None, reason="")
        message = ("[reintentar] La persona quiere que lo intentes otra vez con la misma opción. Mira en qué "
                   "punto está la tienda y sigue; si vuelve a fallar, termina con «BLOQUEADO: …».")
    resume(home, errand_id, message)
    return get(home, errand_id)


def _offer_lines(offer: Dict[str, Any]) -> str:
    variant = offer.get("variant") or "la que muestra la página"
    start = (f"Abre el carrito del catálogo ({offer['checkout_url']}), que ya lleva esa variante, o si no "
             f"carga, la página del producto ({offer['url']})."
             if offer.get("channel") == "catalog" and offer.get("checkout_url")
             else f"Abre la página del producto: {offer['url']}.")
    return (
        f"La persona eligió exactamente esto: {offer.get('title')} · variante: {variant} · cantidad: "
        f"{offer.get('qty') or 1} · {offer.get('merchant') or 'la tienda'} · {offer.get('price')} "
        f"({offer.get('currency') or ''}). {start} Compra eso y nada más: no lo cambies por otro producto, "
        "otra variante u otra tienda. Empieza con la cesta solo con esta opción: si tiene otros artículos de "
        "intentos anteriores, quítalos sin preguntar. Si ya no está disponible, la variante no existe o el precio es otro, no "
        "sigas: termina tu turno con una sola línea «BLOQUEADO: precio 34,99 € — por qué» (con el precio que "
        "cobra la tienda, si ese es el cambio) o «BLOQUEADO: qué ha cambiado». La persona decide si sigue."
    )


# How a saved card is filled, given by the plugin (vault_cards.prompt) so it reaches the errand,
# the only place that pays, instead of every chat's prompt.
card_rules: Callable[[str], str] = lambda profile: ""


def brief(entry: Dict[str, Any]) -> str:
    """The first message of an errand's session."""
    login = ("Antes de iniciar sesión, la persona quiere que se le pregunte: Hermes se lo pedirá."
             if entry.get("ask_before_login") else
             "Si la web pide iniciar sesión y hay un login guardado en el vault para ella, entra con "
             "`browser_vault_fill` sin preguntar.")
    offer = entry.get("offer") if isinstance(entry.get("offer"), dict) else None
    what = (_offer_lines(offer) + " " if offer else
            "Pregunta con `ask_person` solo lo que cambia qué se hace o cuánto cuesta, todo en una sola vez "
            "y al principio. ")
    return (
        f"[Recado de Alice] {entry['request']}\n\n"
        "Trabajas en segundo plano, fuera de cualquier chat: la persona no lee tus respuestas, ve la "
        "tarjeta del recado. Navegas en un contexto propio, sin sesiones iniciadas: si la web pide "
        "entrar, usa el login del vault. Hazlo de principio a fin tú: nunca llames a `errand_start` (ya estás en el "
        "recado). El comentario `#` con que empieza cada paso del navegador es lo que la persona ve: "
        "escríbelo en su idioma y en pocas palabras («Añadir al carrito», «Elegir envío»). "
        f"{login} {what}"
        "Decide tú lo que tenga una opción razonable (tratamiento, envío estándar, sin extras, sin cuenta "
        "nueva si se puede comprar como invitado) y usa los datos de envío guardados. Nunca preguntes por "
        "tarjetas: si una página de pago pide una y `browser_vault_list` no tiene ninguna para ella, llama "
        "a `card_request`. Cuando el pedido esté listo en el paso de pago, NO rellenes la tarjeta ni pulses pagar: "
        "llama a `checkout_request` con lo que muestra la página (tienda, artículos con variante, "
        "cantidad, precio e imagen, entrega, dirección, email, tarjeta y total exacto) y termina tu turno; "
        "si no hay tarjeta con la que pagar, Alice se la pide a la persona antes de enseñarle el total. "
        f"El recado seguirá con «{APPROVED_PREFIX}» si lo aprueba. Después de pagar, registra "
        "`purchase_outcome` con el número de pedido, el total, los artículos, la tarjeta y la entrega "
        "prevista. Termina cada turno con una sola línea que diga en qué punto estás."
        + (("\n\n" + card_rules(str(entry.get("profile") or "default"))) if card_rules(str(entry.get("profile") or "default")) else "")
    )


# ── Its own browser context ────────────────────────────────────────────────────
#
# Every agent shares the one Chrome, and Hermes gives each session its own tab — but tabs share
# cookies, so three copies of one errand filled the same Apple bag. Each errand browses in a
# browser context of its own (cookies, basket, session), made and pinned by a few lines put in
# front of its browser_exec code; a login it needs comes from the vault.

CONTEXT_FILE = "alice-errand-ctx-{id}.json"


def context_file(errand_id: str) -> Path:
    import tempfile

    return Path(tempfile.gettempdir()) / CONTEXT_FILE.format(id=re.sub(r"[^a-f0-9]", "", errand_id))


def context_preamble(errand_id: str) -> str:
    """Code run before the errand's own: it switches the harness to the errand's tab in the
    errand's context, making both when missing. Never stops the errand: on failure it says so."""
    path = str(context_file(errand_id))
    return f"""\
# alice: this errand browses in its own browser context (its own cookies and basket)
def _alice_own_context():
    import json as _j, os as _o
    _path = {path!r}
    try:
        from browser_harness import _ipc as _bipc
        _dpid = _bipc.pid_path(_o.environ.get("BU_NAME", "default")).read_text().strip() or "0"
    except Exception:
        _dpid = "0"
    try:
        _saved = _j.load(open(_path))
    except Exception:
        _saved = {{}}
    try:
        _targets = {{t.get("targetId") for t in cdp("Target.getTargets").get("targetInfos", [])}}
        if _saved.get("daemon") == _dpid and _saved.get("target") in _targets:
            return
        _contexts = set(cdp("Target.getBrowserContexts").get("browserContextIds", []))
        _ctx = _saved.get("context") if _saved.get("context") in _contexts else None
        if _ctx is None:
            _ctx = cdp("Target.createBrowserContext").get("browserContextId")
        _tid = _saved.get("target") if (_saved.get("target") in _targets and _saved.get("context") == _ctx) else None
        if _tid is None:
            _tid = cdp("Target.createTarget", url="about:blank", browserContextId=_ctx).get("targetId")
        switch_tab(_tid)
        _j.dump({{"context": _ctx, "target": _tid, "daemon": _dpid}}, open(_path, "w"))
    except Exception as _e:
        print("[alice] no se pudo aislar el navegador de este recado:", type(_e).__name__)
_alice_own_context()
del _alice_own_context
"""


def release_context(errand_id: str, browser_ws: Optional[str] = None) -> bool:
    """The errand is over: its browser context (and its pages) is closed, its note removed."""
    path = context_file(errand_id)
    try:
        saved = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    try:
        path.unlink()
    except OSError:
        pass
    context = saved.get("context")
    if not context:
        return False
    try:
        if browser_ws is None:
            with urllib.request.urlopen("http://127.0.0.1:9222/json/version", timeout=2) as response:  # noqa: S310
                browser_ws = json.loads(response.read().decode("utf-8"))["webSocketDebuggerUrl"]
        from websockets.sync.client import connect

        with connect(browser_ws, open_timeout=3) as socket:
            socket.send(json.dumps({"id": 1, "method": "Target.disposeBrowserContext",
                                    "params": {"browserContextId": context}}))
            socket.recv(timeout=3)
        return True
    except Exception:  # noqa: BLE001 — a closed Chrome took the context with it
        return False


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


def page_of(url: str) -> str:
    """A page without its query: the same checkout step whatever its tokens."""
    parts = urlsplit(str(url or ""))
    return f"{parts.netloc}{parts.path}".rstrip("/")


def circling(entry: Dict[str, Any]) -> Optional[str]:
    """The page an errand keeps going round on without getting past, or None."""
    steps = [s for s in entry.get("steps") or [] if s.get("url")]
    if len(steps) < CIRCLE_STEPS:
        return None
    last = steps[-CIRCLE_STEPS:]
    page = page_of(last[-1]["url"])
    if any(page_of(s["url"]) != page for s in last):
        return None
    if float(last[-1].get("at") or 0) - float(last[0].get("at") or 0) < CIRCLE_SECONDS:
        return None
    return page


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
            page = circling(self._entry())
            if page and status == "running":
                self.gateway.stop(run_id)
                return {"status": "circling", "page": page}
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
        repeat_recoveries = 0
        self_fixed = False
        stalls = 0
        # Restarted while its last run still goes on in the gateway: that run finishes first,
        # never a second one beside it in the same session.
        if entry.get("run_id") and message:
            try:
                still = str(self.gateway.status(entry["run_id"]).get("status") or "")
            except Exception:  # noqa: BLE001 — gone or unreachable: nothing to wait for
                still = ""
            if still in ("running", "waiting_for_approval", "queued"):
                self._wait_run(entry["run_id"])
                text = CONTINUATION
        while True:
            entry = self._entry()
            if entry.get("status") != "working":
                return entry.get("status", "missing")
            if int(entry.get("runs") or 0) >= MAX_RUNS:
                update(self.home, self.errand_id, status="stuck", reason="Ha usado todos sus intentos sin terminar.")
                return "stuck"
            try:
                steps_before = entry.get("steps") or []
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
            if state.get("status") == "circling":
                update(self.home, self.errand_id, status="stuck", reason=(
                    "Lleva varios minutos en la misma página sin poder avanzar (" + str(state.get("page"))[:80]
                    + "). Ábrela en el navegador para ver qué pide la tienda."))
                return "stuck"
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
            # The chosen option cannot be bought as chosen (gone, another price): it stops here
            # and says why, instead of buying something else.
            if BLOCKED.match(reply):
                said = _clean(BLOCKED.sub("", reply, count=1), 300) or "La opción elegida ya no se puede comprar."
                blocked = blocked_by(said)
                # Only what the person must decide stops the errand: another price, or the option gone.
                # A basket with something else in it, a wrong variant, a page error is the agent's to
                # fix: one checkout stopped on «contains another product» left over from an earlier try.
                if blocked["kind"] == "other" and not self_fixed:
                    self_fixed = True
                    text = (CONTINUATION + " Eso lo resuelves tú, sin contárselo a la persona: " + said + " "
                            "Si la cesta tiene artículos que no son la opción elegida (de intentos anteriores), "
                            "quítalos; corrige variante y cantidad; recarga o vuelve a la ficha si la página falla. "
                            "Luego sigue hasta el paso de pago y llama a `checkout_request`. Solo si la tienda ya "
                            "no vende esa opción o cobra otro precio, termina con «BLOQUEADO: …».")
                    continue
                update(self.home, self.errand_id, status="stuck", reason=said, blocked=blocked)
                return "stuck"
            receipt = entry.get("receipt") or {}
            if receipt.get("outcome") == "paid":
                update(self.home, self.errand_id, status="done")
                return "done"
            # Similar summaries are not a loop when the browser has recorded
            # new steps. Give a real no-progress loop one bounded recovery.
            if previous and repeats(previous, reply) and (entry.get("steps") or []) == steps_before:
                if repeat_recoveries >= 1:
                    last = (entry.get("steps") or [{}])[-1].get("text") or "sin pasos registrados"
                    update(self.home, self.errand_id, status="stuck", reason=(
                        "No ha podido avanzar tras un intento de recuperación. Último paso: " + str(last)[:140] + "."))
                    return "stuck"
                repeat_recoveries += 1
                text = (CONTINUATION + " Has repetido la respuesta sin registrar pasos nuevos. "
                        "Inspecciona el estado actual de la página y lee el error de la tienda antes de "
                        "actuar; no repitas el mismo intento. Si necesitas un dato de la persona, usa "
                        "ask_person o la tarjeta segura correspondiente. Si ya existe un pedido, "
                        "comprueba su confirmación: no vuelvas a pagar. Si nada permite avanzar, "
                        "di el obstáculo concreto. No reinicies el recado.")
                continue
            if (entry.get("steps") or []) != steps_before or not repeats(previous, reply):
                repeat_recoveries = 0
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
            final = (engine_factory or Engine)(home, errand_id).run(message)
            if final in ("done", "stuck", "denied", "stopped", "missing"):
                release_context(errand_id)
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
          now: Optional[float] = None, offer: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """``errand_start``: records the errand, opens its goal and starts it.

    Never from inside an errand (one started three copies of itself, all driving the same
    browser), and a chat that asks again while its errand is under way gets that one. A purchase
    carries ``offer``, the option the person chose; the same option is one errand while active."""
    now = now or time.time()
    if str(origin_session or "").startswith(SESSION_PREFIX):
        return {"ok": False, "errand_id": origin_session[len(SESSION_PREFIX):], "status": "working",
                "error": "You are already inside this errand: do the task here, do not start another."}
    task = _clean(args.get("task"), 1500)
    if not task:
        raise ValueError("Say what the errand is.")
    option_id = (offer or {}).get("option_id")
    # Lookup and insertion share a process-safe lock. The same request remains
    # the same errand for its whole active lifetime; another task is independent.
    with _locked(home) as path:
        entries = _read(path)
        for other in reversed(entries):
            same = (((other.get("offer") or {}).get("option_id") == option_id) if option_id else
                    _clean(other.get("request"), 1500).casefold() == task.casefold())
            if (origin_session and other.get("origin_session") == origin_session
                    and (other.get("profile") or "") == profile and other.get("status") in ACTIVE and same):
                return started_result(other)
        site = str(args.get("site") or "") or str((offer or {}).get("url") or "")
        entry = _new_entry(task, title=str(args.get("title") or ""), site=site,
                           origin_session=origin_session, profile=profile,
                           ask_before_login=bool(args.get("ask_before_login")), now=now, offer=offer)
        entries = [e for e in entries if e.get("status") in ACTIVE
                   or now - float(e.get("updated_at") or 0) < KEEP]
        entries.append(entry)
        _write(path, entries)
    open_goal(entry)
    launch(home, entry["id"])
    return started_result(entry)


def started_result(entry: Dict[str, Any]) -> Dict[str, Any]:
    """The existing errand's identity and actual state, also used by the chat's tool."""
    return {"errand_id": entry["id"], "title": entry["title"], "status": entry["status"],
            "next": "Report this errand's actual status in one short line. Alice shows its progress. "
                    "Do not start another or do it here."}


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
    entry = update(home, errand_id, status="stopped", reason="El recado se ha detenido.")
    try:
        _goal_manager(entry["session_id"]).clear()
    except Exception:
        pass
    if entry.get("run_id"):
        Gateway(home, entry.get("profile") or "").stop(entry["run_id"])
    release_context(errand_id)
    return entry


def public(entry: Dict[str, Any]) -> Dict[str, Any]:
    """What Alice shows: everything but the internal session wiring."""
    # The chat it came from stays: Alice finds an errand's cards by it when the chat's reply
    # never called errand_start (the plugin starts it anyway).
    hidden = {"run_id"}
    out = {k: v for k, v in entry.items() if k not in hidden}
    if isinstance(out.get("approval"), dict):
        out["approval"] = {k: v for k, v in out["approval"].items() if k != "run_id"}
    return out


PROMPT = (
    "## Recados\n"
    "Lo que se hace en una web por la persona —una compra, una reserva, un formulario— es un recado: "
    "corre aparte, con su tarjeta en el chat y en «Recados», y nada se paga sin su aprobación. Una "
    "**compra** sigue «Comprar»: aquí aclaras, buscas y enseñas opciones; el recado empieza solo con "
    "la opción que ella elige (`errand_start` con su `option_id`). Otro recado (una reserva, un "
    "trámite) empieza con `errand_start` y lo que pidió, en una línea. Solo si la persona pide que se le "
    "pregunte antes de iniciar sesión, pasa `ask_before_login: true`. No hables de otros recados ni de "
    "compras anteriores salvo que te pregunte por ellos, y su estado real es el de su tarjeta, no el que "
    "diga la conversación."
)
