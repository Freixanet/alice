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
import logging
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
STATUSES = ("working", "needs_approval", "needs_input", "needs_card", "needs_login", "done", "stuck", "stopped", "denied")
ACTIVE = ("working", "needs_approval", "needs_input", "needs_card", "needs_login")
# An approved checkout pays within this window; later, the agent asks again. Long enough for a
# bank's 3-D Secure step and the person's answer in their bank app; the amount on the shop's
# page is re-read before the card goes in anyway.
APPROVAL_TTL = 20 * 60
# A checkout waiting longer than this is stale (shops close their checkout sessions; prices
# and delivery move): it can no longer be approved, only prepared again. An approval that comes
# late within the window is still paid only after the total is read again on the page.
CHECKOUT_TTL = 45 * 60
KEEP = 30 * 24 * 3600
MAX_STEPS = 40
POLL_SECONDS = 1.5
# One errand: at most this many runs, whatever the judge says.
MAX_RUNS = 14
# A run with no event for this long has stalled (a model call that never returned): it is
# stopped and the errand goes on once; a second stall leaves it stuck.
STALL_SECONDS = 240
# Going round in circles on one page (a form the shop keeps rejecting): this many steps on
# the same page over this long. One-page checkouts (Prozis, Shopify, Magento keep basket,
# address, delivery and payment on one path) take many steps there while moving on, so the first
# time the errand is only told to read the page's error; a second round stops it and says so.
CIRCLE_STEPS = 12
CIRCLE_SECONDS = 240

CONTINUATION = "[Continuing toward your standing goal]"
APPROVED_PREFIX = "[checkout aprobado]"

# What a button that pays says, in the code or arguments of a browser action.
PAY_WORDS = re.compile(
    r"\b(pagar|pago ahora|realizar (el )?pedido|confirmar (el )?pedido|confirmar y pagar"
    r"|comprar (ya|ahora)|place (your )?order|pay now|buy now|complete (purchase|order)"
    r"|confirm (and pay|purchase|order)|submit order)\b", re.I)
# Words a cart's "go on" button also says («Finalizar compra» opens login and delivery). They
# count as paying unless the errand's page was read and shows no payment step.
STEP_WORDS = re.compile(r"\b(finalizar (la )?compra|tramitar (el )?pedido)\b", re.I)
# Whether a page shows a payment step: card fields, a payment provider's frame, or a choice of
# payment method. A cart lists logos and totals, never these controls.
PAYMENT_STEP_JS = r"""(()=>{const seen=e=>e.getClientRects().length>0&&getComputedStyle(e).visibility!=="hidden";
const card=/cc-|card|tarjeta|cvc|cvv|expir|caducidad/i;
if(Array.from(document.querySelectorAll('input,select')).some(e=>seen(e)&&card.test([e.autocomplete,e.name,e.id,e.placeholder].join(' '))))return true;
if(Array.from(document.querySelectorAll('iframe')).some(f=>seen(f)&&/stripe|adyen|braintree|checkout\.com|redsys|paypal|klarna|worldpay|mollie|square/i.test(f.src+' '+f.name)))return true;
return Array.from(document.querySelectorAll('input[type=radio]')).some(e=>{const l=e.closest('label')||document.querySelector('label[for="'+e.id+'"]')||e.parentElement;return seen(l||e)&&/tarjeta|card|paypal|bizum|klarna|apple pay|google pay|transferencia|contra ?reembolso|cash on delivery/i.test(l?l.innerText:'')});})()"""
# A page where the next click can pay: the payment or review step of a checkout.
PAY_PAGE = re.compile(
    r"(/step/payment|/payment\b|/pago\b|/pay\b|/checkout/(review|confirm|payment|pago)|/confirmacion|/confirm\b"
    r"|onepage|/order-review|/revisar)", re.I)
# On that page, picking how to pay (the card radio, PayPal, Bizum) or accepting the terms is not
# paying: the agent must be able to reach the final total before it asks for the approval.
METHOD_WORDS = re.compile(
    r"(tarjeta|credit|debit|\bcard\b|paypal|bizum|klarna|apple pay|google pay|transferencia|contra ?reembolso"
    r"|m[eé]todo|method|forma de pago|acepto|condiciones|terms|privacidad|privacy|newsletter|radio|checkbox)", re.I)
# Browser actions that can press something on the page (Browser Use code or built-in tools).
CLICKS = re.compile(r"(click|submit|press|dispatchMouseEvent|dispatchKeyEvent|Enter|\.requestSubmit)", re.I)
BROWSER_ACTIONS = ("browser_exec", "browser_click", "browser_press", "browser_type")
# Hermes tools that run any code in the page, send raw DevTools commands or answer the page's own
# «Confirm purchase?» dialog: each can pay like a click, so each passes the same gate.
RAW_BROWSER = ("browser_console", "browser_cdp", "browser_dialog")
# DevTools methods that only read.
_CDP_READS = re.compile(r"^(Target\.get|Target\.attachToTarget|DOM\.(get|query|describe|resolve)|Page\.get"
                        r"|Network\.get|Accessibility\.get|CSS\.get|Browser\.get)")


def _money():
    """money.py beside this file (plugins load modules by path, not as a package)."""
    import importlib.util
    import sys as _sys

    name = "alice_money"
    # Under the loader's lock: a module half-loaded by another thread had no `parse` yet and
    # broke the phone's purchase list mid-approval (06-10).
    import threading as _threading
    with _sys.__dict__.setdefault('_alice_module_load_lock', _threading.RLock()):
        if name not in _sys.modules:
            spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "money.py")
            module = importlib.util.module_from_spec(spec)
            _sys.modules[name] = module
            spec.loader.exec_module(module)
        return _sys.modules[name]


def _purchases():
    """purchases.py beside this file: the ledger of payments sent, one entry per order."""
    import importlib.util
    import sys as _sys

    name = "alice_purchases"
    # Under the loader's lock: a module half-loaded by another thread had no `parse` yet and
    # broke the phone's purchase list mid-approval (06-10).
    import threading as _threading
    with _sys.__dict__.setdefault('_alice_module_load_lock', _threading.RLock()):
        if name not in _sys.modules:
            spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "purchases.py")
            module = importlib.util.module_from_spec(spec)
            _sys.modules[name] = module
            spec.loader.exec_module(module)
        return _sys.modules[name]


def payment_pending(home: Path, entry: Dict[str, Any], now: Optional[float] = None) -> bool:
    """Whether money may be out without a known outcome: a payment this errand sent is still open
    in the ledger, or the person approved its checkout and nothing says how that ended."""
    if not entry or isinstance(entry.get("receipt"), dict) and entry["receipt"].get("outcome"):
        return False
    try:
        if _purchases().open_payment(home, str(entry.get("session_id") or ""), now=now) is not None:
            return True
    except Exception:  # noqa: BLE001 — an unreadable ledger is not "nothing was paid"
        return True
    checkout = entry.get("checkout") if isinstance(entry.get("checkout"), dict) else {}
    return checkout.get("status") == "approved"


def close_unknown(home: Path, errand_id: str, now: Optional[float] = None) -> bool:
    """A payment that may have gone out and whose outcome nobody read ends as «unknown»: written in
    the ledger (so the shop is not paid again without the person) and on the errand's receipt (so
    the card says it is not known, never «nothing was paid»). False when nothing was pending."""
    entry = get(home, errand_id)
    if entry is None or not payment_pending(home, entry, now):
        return False
    site = ((entry.get("checkout") or {}).get("site") if isinstance(entry.get("checkout"), dict) else "") \
        or entry.get("site") or shop(((entry.get("offer") or {}).get("url") or ""))
    try:
        _purchases().settle(home, site, "unknown", now=now, ensure_session=str(entry.get("session_id") or ""))
    except Exception:  # noqa: BLE001 — the receipt still says unknown
        pass
    record_receipt(home, str(entry.get("session_id") or ""), {"site": site, "outcome": "unknown"}, now=now)
    return True


UNKNOWN_REASON = ("No se pudo confirmar si el pago se hizo. Comprueba «Mis pedidos» en la tienda o el correo "
                  "del pedido antes de volver a pagar; no se volverá a pagar sin ti.")


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


def set_aside(path: Path) -> None:
    """An unreadable store is moved beside itself (``.corrupt-<time>``), never overwritten: the
    next write would otherwise replace the person's errands with an empty list."""
    try:
        Path(path).rename(Path(str(path) + f".corrupt-{int(time.time())}"))
    except OSError:
        pass


def _read(path: Path) -> List[Dict[str, Any]]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError:
        return []
    except ValueError:
        set_aside(path)
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


def model_selection(home: Path) -> Dict[str, str]:
    """The person's fixed errand model, independent of any chat's current model.

    A local override survives plugin updates. An invalid file fails visibly instead of
    falling back to Hermes' current model. Each errand saves this selection once.
    """
    path = Path(home) / ".alice" / "errand-model.json"
    if not path.exists():
        path = Path(__file__).with_name("errand-model.json")
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError("No se pudo leer el modelo fijo de los recados.") from exc
    if not isinstance(config, dict):
        raise ValueError("El modelo de los recados requiere model y provider.")
    model, provider = config.get("model"), config.get("provider")
    if (not isinstance(model, str) or not isinstance(provider, str)
            or not model.strip() or len(model) > 160 or re.search(r"\s", model.strip())
            or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", provider)):
        raise ValueError("El modelo de los recados requiere model y provider válidos.")
    return {"model": model.strip(), "provider": provider}


def _new_entry(task: str, *, title: str = "", site: str = "", origin_session: str = "",
               profile: str = "", ask_before_login: bool = False, now: float,
               offer: Optional[Dict[str, Any]] = None,
               model_route: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    task = _clean(task, 1500)
    if not task:
        raise ValueError("Say what the errand is.")
    errand_id = secrets.token_hex(5)
    return {
        "id": errand_id, "title": _clean(title, 80) or task[:80], "request": task, "site": shop(site),
        "status": "working", "session_id": SESSION_PREFIX + errand_id, "run_id": "", "runs": 0,
        "origin_session": _clean(origin_session, 120), "profile": _clean(profile, 64),
        **(model_route or {}),
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
                       profile=profile, ask_before_login=ask_before_login, now=now, offer=offer,
                       model_route=model_selection(home))
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

# How a shop gets paid. Only «card» needs a saved card in the vault: the others are finished on the
# shop's or the provider's page, by the agent or by the person taking the browser, and the plugin
# writes them down all the same (purchases.py) so an order is never paid twice.
PAYMENT_METHODS = {
    "card": "tarjeta guardada", "saved_on_shop": "la tarjeta guardada en la tienda", "paypal": "PayPal",
    "bizum": "Bizum", "apple_pay": "Apple Pay", "transfer": "transferencia", "cod": "contra reembolso",
}

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
            "payment_method": {"type": "string", "enum": list(PAYMENT_METHODS),
                               "description": "How the shop will be paid, as chosen on its page: card (a saved "
                                              "card Alice fills; the default), saved_on_shop (a card the shop "
                                              "keeps), paypal, bizum, apple_pay, transfer or cod"},
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


def _safe_fetch():
    import importlib.util
    import sys as _sys

    name = "alice_safe_fetch"
    # Under the loader's lock: a module half-loaded by another thread had no `parse` yet and
    # broke the phone's purchase list mid-approval (06-10).
    import threading as _threading
    with _sys.__dict__.setdefault('_alice_module_load_lock', _threading.RLock()):
        if name not in _sys.modules:
            spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "safe_fetch.py")
            module = importlib.util.module_from_spec(spec)
            _sys.modules[name] = module
            spec.loader.exec_module(module)
        return _sys.modules[name]


def _fetch(url: str, limit: int, accept: str) -> Tuple[bytes, str]:
    # A picture address the model chose: public https only, redirects included (safe_fetch.py).
    return _safe_fetch().fetch(url, {"User-Agent": USER_AGENT, "Accept": accept}, limit, 6)


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
    amount = _money().parse(args.get("total"), _clean(args.get("currency"), 8))
    if not amount or not amount[1]:
        return {"ok": False, "error": "Read one valid total and its currency from the checkout page."}
    total_cents, currency = amount
    total = _money().text(total_cents, currency)
    # Step 8: a way to pay before the person sees the total. With no saved card the person is asked
    # for one first; the errand resumes with «[tarjeta lista]» and calls checkout_request again.
    labels: List[str] = []
    method = str(args.get("payment_method") or "card").strip().lower()
    if method not in PAYMENT_METHODS:
        method = "card"
    if saved_cards is not None and method == "card":
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
        "card_label": (paying_card(home, site, [label for label in labels if label != "?"],
                                   _clean(args.get("card_label"), 60)) if method == "card" else ""),
        "payment_method": method,
        "total": total, "total_cents": total_cents, "currency": currency, "requested_at": now,
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
    # Read and written under one lock: an approval made a moment ago is never overwritten by a stale copy.
    with _locked(home) as path:
        entries = _read(path)
        for entry in entries:
            checkout = entry.get("checkout")
            if (isinstance(checkout, dict) and checkout.get("status") == "pending"
                    and now - float(checkout.get("requested_at") or now) > CHECKOUT_TTL):
                entry["checkout"] = {**checkout, "status": "expired"}
                entry["updated_at"] = now
                expired.append(entry["id"])
        if expired:
            _write(path, entries)
    return expired


def refresh_message(checkout: Dict[str, Any]) -> str:
    return (f"[checkout caducado] El checkout de {checkout.get('merchant') or checkout.get('site')} esperó demasiado y "
            "ya no vale. Vuelve a la tienda, comprueba que el pedido sigue igual (artículos, precio, envío), llega "
            "otra vez al paso de pago y llama a `checkout_request` con lo que muestre la página ahora. No pagues.")


def decide_checkout(home: Path, errand_id: str, allow: bool, now: Optional[float] = None,
                    card_label: str = "") -> Optional[Dict[str, Any]]:
    now = now or time.time()
    expire_checkouts(home, now)
    # Checked and decided under one lock: «Permitir» and «Denegar» arriving together (phone and
    # watch) decide once; the second finds the checkout no longer pending.
    with _locked(home) as path:
        entries = _read(path)
        entry = next((e for e in entries if e.get("id") == errand_id), None)
        checkout = (entry or {}).get("checkout")
        if entry is None or not isinstance(checkout, dict) or checkout.get("status") != "pending":
            return None
        # Existing archives may predate cents. Validate them before granting payment approval.
        amount = _money().parse(checkout.get("total"), checkout.get("currency") or "") if allow else None
        if allow and (not amount or not amount[1]):
            return None
        checkout = {**checkout, "status": "approved" if allow else "denied", "decided_at": now}
        if allow:
            # The yes is to this total, kept in cents for the code that checks the payment page.
            checkout["approved_total"] = checkout.get("total", "")
            checkout["total_cents"], checkout["currency"] = amount
            checkout["approved_cents"], checkout["approved_currency"] = amount
        if allow and _clean(card_label, 60):
            checkout["card_label"] = _clean(card_label, 60)
        entry.update(checkout=checkout, status="working" if allow else "denied",
                     reason="" if allow else "Has denegado la compra.", updated_at=now)
        _write(path, entries)
    decided = entry
    if not allow:
        # Denied while parked: no engine is left to close its page, so it is closed here.
        try:
            release_context(errand_id, home=home)
        except Exception:  # noqa: BLE001
            pass
    return decided


def approved_message(checkout: Dict[str, Any]) -> str:
    """How the errand goes on after «Permitir»: pay that total, that way, and nothing else."""
    total = checkout.get("approved_total") or checkout.get("total") or ""
    card = f" ({checkout['card_label']})" if checkout.get("card_label") else ""
    method = str(checkout.get("payment_method") or "card")
    if method == "card":
        how = f"paga con la tarjeta guardada{card}"
    else:
        how = (f"paga con {PAYMENT_METHODS.get(method, method)}: pulsa el botón que paga y, si la tienda te lleva a "
               "una página o app donde haga falta la persona (PayPal, Bizum, el banco), dilo en una línea y espera "
               "mirando la página (lee cada 20 s, hasta unos 3 minutos) a que termine ahí")
    return (
        f"{APPROVED_PREFIX} La persona ha aprobado pagar {total} en {checkout.get('merchant') or checkout.get('site')}. "
        f"Justo antes de pulsar pagar, mira el total de la página: si es exactamente {total}, {how}; si es otro, "
        "NO pagues y vuelve a llamar a `checkout_request` con lo que "
        "muestra ahora. Después de pagar, registra `purchase_outcome` con el número de pedido, el total, "
        "los artículos, la tarjeta y la entrega prevista; si no ves cómo acabó, `unknown`, nunca otro intento.")


def same_amount(a: Any, b: Any) -> bool:
    """«27,98 €» and «EUR 27.98» are the same amount; «2798 €» is not (money.same, in cents)."""
    return _money().same(a, b)


def approved_checkout(entry: Optional[Dict[str, Any]], site: str = "", now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """The errand's checkout the person approved, still fresh, for this shop (any shop when blank)."""
    now = now or time.time()
    checkout = (entry or {}).get("checkout")
    if not isinstance(checkout, dict) or checkout.get("status") != "approved":
        return None
    # A stopped, denied or finished errand pays nothing, whatever its checkout says.
    if (entry or {}).get("status") != "working":
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


def is_pay_action(tool_name: str, args: Any, active_url: str = "", payment_step: Optional[bool] = None) -> bool:
    """A browser action that can pay: it names the pay button, or it presses something on a pay page.

    ``payment_step`` is what the errand's own page shows (None when unread): a cart's «Finalizar
    compra» is let through only when the page was read and has no payment step."""
    if tool_name in RAW_BROWSER:
        # Same reading as a click; inside an errand any press through these needs the approval
        # anyway (pay_gate's ``press_pays``).
        text = _text_of(args)
        return _raw_presses(tool_name, args) and bool(
            PAY_WORDS.search(text) or PAY_PAGE.search(str(active_url or "")) or payment_step
            or (STEP_WORDS.search(text) and payment_step is None))
    if tool_name not in BROWSER_ACTIONS:
        return False
    text = _text_of(args)
    presses = tool_name in ("browser_click", "browser_press") or bool(CLICKS.search(text))
    if not presses:
        # Reading a page or searching for pay controls does not submit an order.
        return False
    if PAY_WORDS.search(text) or payment_step:
        return True
    if PAY_PAGE.search(str(active_url or "")):
        return not METHOD_WORDS.search(text)
    return bool(STEP_WORDS.search(text)) and payment_step is None


def is_strong_pay_action(tool_name: str, args: Any, active_url: str = "", gateways: Iterable[str] = ()) -> bool:
    """A press that pays by itself, worth writing in the ledger before it happens: it names the pay
    button, or it presses anything on a bank's own payment page. A «Continuar» on the payment step
    is not one (it may only move on), so it leaves no entry."""
    if tool_name not in BROWSER_ACTIONS:
        return False
    text = _text_of(args)
    presses = tool_name in ("browser_click", "browser_press") or bool(CLICKS.search(text))
    if not presses:
        return False
    if PAY_WORDS.search(text):
        return True
    host = (urlsplit(str(active_url or "")).hostname or "").lower()
    return bool(host) and host in {str(g).lower() for g in gateways}


def _raw_presses(tool_name: str, args: Any) -> bool:
    """A RAW_BROWSER call that can press or submit something (reading the page or the console cannot)."""
    a = args if isinstance(args, dict) else {}
    if tool_name == "browser_dialog":
        return str(a.get("action") or "").lower() != "dismiss"
    if tool_name == "browser_cdp":
        return not _CDP_READS.search(str(a.get("method") or ""))
    expression = str(a.get("expression") or "")
    return bool(expression.strip()) and bool(CLICKS.search(expression) or re.search(
        r"dispatchEvent|\.submit\b|location\s*=|location\.(assign|replace|href)|fetch\s*\(|XMLHttpRequest|sendBeacon",
        expression))


def pay_gate(home: Path, session_id: str, *, card_fill_site: Optional[str] = None, tool_name: str = "",
             args: Any = None, active_url: str = "", gateways: Iterable[str] = (),
             merchant_site: str = "", now: Optional[float] = None,
             payment_step: Optional[bool] = None, press_pays: bool = False) -> Optional[Dict[str, str]]:
    """A pre_tool_call directive that refuses paying without the person's approved checkout, or None.

    ``card_fill_site`` is the page a saved payment card is about to be written into (None when
    the call is not a card fill); otherwise the call is checked as a browser action."""
    filling = card_fill_site is not None
    if not filling and not press_pays and not is_pay_action(tool_name, args, active_url, payment_step):
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
        fresh = approved_checkout(entry, now=now)
        # The press happens on the approved shop or on the bank page it sent the person to.
        host = shop(active_url or "")
        banks = {shop(g) for g in gateways}
        ok = fresh is not None and (not host or host == fresh.get("site") or host in banks)
    if ok:
        return None
    return {"action": "block", "message": (
        "No se paga sin la aprobación de la persona. Con el checkout listo en el paso de pago, llama a "
        "`checkout_request` con lo que muestra la página (tienda, artículos, entrega, tarjeta, total) y "
        f"termina tu turno; el recado sigue con «{APPROVED_PREFIX}» cuando la persona lo apruebe. "
        f"Si ya se aprobó hace más de {APPROVAL_TTL // 60} minutos o en otra tienda, pide la aprobación otra vez.")}


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
    amount = _money().parse(receipt["total"], checkout.get("approved_currency") or checkout.get("currency") or "")
    if amount:
        receipt["total_cents"], receipt["currency"] = amount
    expected = (checkout.get("approved_cents"), checkout.get("approved_currency"))
    if expected[0] is None:
        expected = _money().parse(approved, checkout.get("currency") or "")
    if approved and receipt["total"] and (not amount or amount != expected):
        receipt["approved_total"] = approved
    fields: Dict[str, Any] = {"receipt": receipt}
    # One approval pays once: after a payment (or one whose result is unknown) it is spent.
    if checkout.get("status") == "approved" and receipt["outcome"] not in ("declined", "not_charged"):
        fields["checkout"] = {**checkout, "status": "consumed", "consumed_at": now or time.time()}
    update(home, entry["id"], now=now, **fields)



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
        "from the option the person TAPPED among those shown with `purchase_options` (the plugin starts "
        "it from the tap and carries its page, variant, quantity and price; words such as «la segunda» "
        "do not choose: ask them to tap the card). Anything else — a "
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


UNITS = re.compile(r"\b(\d+\s+unidades|unidades|cantidad|units|quantity|\d+\s*x\b|x\s*\d+)\b", re.I)


def _multiple(price: str, offer: Dict[str, Any]) -> bool:
    """A basket total that is the chosen price times the units in it, not another price."""
    currency = offer.get("currency") or ""
    found, chosen = _money().parse(price, currency), _money().parse(str(offer.get("price") or ""), currency)
    if not found or not chosen or not chosen[0]:
        return False
    times = found[0] / chosen[0]
    return times >= 2 and abs(times - round(times)) < 1e-9


# A shop asking for something only the person has: a question of one line, never a stop.
# «Prozis exige una fecha de nacimiento para crear la cuenta» ended the purchase.
DATA = (
    (r"fecha de nacimiento|birth ?date|date of birth|cumplea[nñ]os|nacimiento", "birthdate", "Fecha de nacimiento (dd/mm/aaaa)"),
    (r"\b(dni|nif|nie|documento de identidad|pasaporte|passport|id number)\b", "id", "DNI / NIF"),
    (r"tel[eé]fono|m[oó]vil|phone", "phone", "Teléfono"),
    (r"c[oó]digo postal|postcode|zip", "postcode", "Código postal"),
    (r"direcci[oó]n|address|calle", "address", "Dirección (calle y número)"),
    (r"localidad|ciudad|city|poblaci[oó]n", "city", "Localidad"),
    (r"provincia|province", "province", "Provincia"),
    (r"apellidos?|surname|last name", "surname", "Apellidos"),
    (r"\bnombre\b|first name", "name", "Nombre"),
    (r"e-?mail|correo", "email", "Email"),
)
NEEDS = re.compile(r"(exige|requiere|pide|necesita|falta|obligatori|required|requires|needs|missing|no permite continuar sin)", re.I)


def missing_datum(said: str) -> Optional[Dict[str, str]]:
    """The personal datum a shop demands, read from the agent's stop, or None."""
    if not NEEDS.search(said):
        return None
    for pattern, field, label in DATA:
        if re.search(pattern, said, re.I):
            return {"field": field, "label": label}
    return None


def ask_datum(home: Path, errand_id: str, datum: Dict[str, str]) -> Optional[Dict[str, Any]]:
    """The errand waits for that one datum on its card; the answer is kept and it goes on."""
    return update(home, errand_id, status="needs_input", blocked=None, reason="",
                  questions={"title": "La tienda pide un dato", "fields": True, "items": [
                      {"id": datum["field"], "question": datum["label"], "field": datum["field"], "choices": []}]})


def convert_datum_stops(home: Path) -> List[str]:
    """Errands stopped on a datum before this rule existed (or by a run this engine did not drive)
    become the question they should have been. Run with every listing."""
    converted = []
    for entry in listing(home):
        datum = missing_datum(str(entry.get("reason") or "")) if entry.get("status") == "stuck" else None
        if datum:
            ask_datum(home, entry["id"], datum)
            converted.append(entry["id"])
    return converted


def blocked_by(said: str, offer: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """What stopped the chosen option: another price (the person may accept it), the option gone,
    a datum only the person has (asked, not a stop), or anything else — the agent's to fix."""
    if re.search(r"iniciar sesi[oó]n|inicio de sesi[oó]n|no inici[oó] sesi[oó]n|no (?:ha )?iniciado sesi[oó]n|sign.?in|log.?in|acceso (?:guardado|rechazado)|error de autenticaci[oó]n|authentication (?:error|failed)|invalid credentials|rechaz[oó].*acceso|completar.*acceso|requires.*account", said, re.I):
        return {"kind": "access"}
    datum = missing_datum(said)
    if datum:
        return {"kind": "datum", **datum}
    if UNITS.search(said):
        # Extra units in the basket (left from another try, a double click) are the agent's to
        # remove, never a price for the person to accept.
        return {"kind": "other"}
    # «precio 34,99 €», «cobra 34,99 €», «la ficha permite 80 cápsulas por 23,99 €»: another price.
    if re.search(r"\b(precio|price|cuesta|cobra|vale|costs?)\b|\bpor\s+[\d€$]", said, re.I):
        currency = (offer or {}).get("currency") or ""
        chosen = _money().parse(str((offer or {}).get("price") or ""), currency) if offer else None
        # The first amount said is the shop's («23,99 €, no por los 29,99 € elegidos»); a crossed-out
        # one comes after it («24,49 € frente a 34,99 € tachados»).
        found = PRICE.search(said)
        if found:
            price = " ".join(found.group(1).split())
            if offer and _money().same(price, offer.get("price"), currency):
                return {"kind": "other"}
            if offer and _multiple(price, offer):
                return {"kind": "other"}
            seen = _money().parse(price, currency)
            if chosen and seen and 0 < seen[0] < chosen[0]:
                # Cheaper than chosen only got better for the person: never a reason to stop.
                return {"kind": "cheaper", "price": price}
            return {"kind": "price", "price": price}
    if re.search(r"navegador|browser|controles|controls", said, re.I):
        return {"kind": "other"}
    if GONE.search(said):
        return {"kind": "gone"}
    return {"kind": "other"}


def basket_prices(home: Path, now: Optional[float] = None, within: float = 7 * 24 * 3600,
                  after: float = 0, offer: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    """The price a basket showed for a product page, from purchases stopped on it lately (newest wins)."""
    now = now or time.time()
    prices: Dict[str, str] = {}
    for entry in sorted(listing(home), key=lambda e: float(e.get("updated_at") or 0)):
        blocked, previous_offer = entry.get("blocked"), entry.get("offer")
        if float(entry.get("updated_at") or 0) <= after:
            continue
        if offer and (not isinstance(previous_offer, dict) or any(
                previous_offer.get(k, 1 if k == "qty" else "") != offer.get(k, 1 if k == "qty" else "")
                for k in ("variant", "qty", "currency"))):
            continue
        if (isinstance(blocked, dict) and blocked.get("kind") == "price" and blocked.get("price")
                and isinstance(previous_offer, dict) and previous_offer.get("url") and now - float(entry.get("updated_at") or 0) < within):
            prices[str(previous_offer["url"]).split("?")[0].rstrip("/")] = blocked["price"]
    return prices


def access_blocked(entry):
    # Includes stopped errands from older versions, which had only a generic blocked reason.
    blocked = entry.get("blocked") or {}
    return blocked.get("kind") == "access" or blocked_by(str(entry.get("reason") or ""), entry.get("offer"))["kind"] == "access"


def go_on(home: Path, errand_id: str, accept_price: bool = False) -> Optional[Dict[str, Any]]:
    """The person's way on from a stopped purchase: the same option at the shop's price, or a retry.
    Nothing is paid by this: the errand goes back to the checkout and asks for that exact total."""
    entry = get(home, errand_id)
    if entry is None or entry.get("status") != "stuck":
        return None
    blocked = entry.get("blocked") if isinstance(entry.get("blocked"), dict) else {}
    offer = entry.get("offer") if isinstance(entry.get("offer"), dict) else None
    receipt = entry.get("receipt") if isinstance(entry.get("receipt"), dict) else {}
    datum = missing_datum(str(entry.get("reason") or "")) if not accept_price else None
    if datum:
        # «Seguir desde aquí» on a stop about a datum: the datum is the way on, not another try.
        return ask_datum(home, errand_id, datum)
    if receipt.get("outcome") == "unknown":
        # Stopped with money possibly out: going on means finding out, never paying again.
        update(home, errand_id, blocked=None, reason="", receipt=None)
        message = ("[comprobar pago] La persona quiere saber cómo acabó el pago que se envió. Mira la página de "
                   "confirmación, «Mis pedidos» en la tienda o el correo del pedido y registra `purchase_outcome` "
                   "con lo que veas (paid con el número de pedido, declined, not_charged o unknown si sigue sin "
                   "estar claro). No vuelvas a pagar.")
        resume(home, errand_id, message)
        return get(home, errand_id)
    if blocked.get("kind") == "paid_before" and not accept_price:
        # The person says this is another order: exactly one payment may go through, within the
        # approval window; the approved total is still read from the page before anything is paid.
        now = time.time()
        update(home, errand_id, blocked=None, reason="", pay_again_until=now + APPROVAL_TTL)
        message = ("[pagar otra vez] La persona confirma que este es un pedido distinto del que ya se pagó en esta "
                   "tienda. Sigue desde el paso de pago: comprueba que el total de la página es el aprobado (si la "
                   "aprobación caducó, llama a `checkout_request` otra vez) y paga una sola vez. Después, "
                   "`purchase_outcome`.")
        resume(home, errand_id, message)
        return get(home, errand_id)
    if access_blocked(entry) and not accept_price:
        update(home, errand_id, blocked=None, reason="", login_declined=False,
               guest_failed=bool(entry.get("guest_failed") or entry.get("login_declined")))
        message = ("[resolver acceso] La persona quiere resolver el acceso a esta tienda y continuar con el mismo "
                   "producto y la misma cesta. Usa el acceso ya elegido con login_fill; si falta, solicita "
                   "login_request. Si pide un código que no tiene, recupera el acceso con contraseña, reenvío "
                   "o cambio de canal. No cambies de cuenta ni de producto. No pagues sin aprobación.")
        if (entry.get("saved_login") or {}).get("handle") or entry.get("user_login_provided"):
            message = ("[comprobar acceso] La persona ya proporcionó el acceso y quiere continuar desde la página actual. "
                       "Relee primero esa página: puede haber completado el acceso en el navegador. Si la sesión está "
                       "abierta, continúa con la cesta sin volver a abrir login o registro. Conserva la cuenta elegida. "
                       "No solicites de nuevo email y contraseña ni crees otra cuenta. Si aún hay un bloqueo, lee el "
                       "mensaje concreto de la tienda; pide un código seguro solo si existe ese campo. No pagues sin aprobación.")
        resume(home, errand_id, message)
        return get(home, errand_id)
    if accept_price:
        if blocked.get("kind") != "price" or not blocked.get("price"):
            return None
        price = blocked["price"]
        if offer:
            offer = {**offer, "price": price}
        update(home, errand_id, offer=offer, blocked=None, reason="")
        message = (f"[precio aceptado] La persona acepta la misma opción a {price}. Llama a `purchase_check_cart` "
                   "(la cesta ya está comprobada a ese precio: confirmará sin preguntar), sigue con el carrito hasta "
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
        "intentos anteriores, quítalos sin preguntar, y si tiene más unidades de las elegidas, déjala en "
        f"{offer.get('qty') or 1} sin preguntar: eso no es un cambio de precio. Si la ficha exige elegir algo que la opción no dice (sabor, color, talla), elige "
        "sin preguntar el neutro o sin sabor, o el primero disponible al mismo precio, y nómbralo en el resumen: "
        "no es un bloqueo. Si la ficha o la cesta piden lo mismo o menos (un cupón, una oferta), "
        "sigue con ese precio: no es un cambio que la persona deba aceptar. Si ya no está disponible, la "
        "variante no existe o el precio es mayor, no sigas: termina tu turno con una sola línea «BLOQUEADO: "
        "precio 34,99 € — por qué» (con el precio que cobra la cesta) o «BLOQUEADO: qué ha cambiado». Un precio anterior "
        "tachado no es un cambio: selecciona la variante, añade el producto y verifica el precio en la cesta. "
        "Si la tienda pide un dato de la persona que no tienes (fecha de nacimiento, DNI, teléfono…), no es un "
        "bloqueo: pregúntalo con `ask_person` con su `field` y termina el turno; sigue cuando llegue. "
        "Si hay un error de código o una página vacía, corrígelo y vuelve a inspeccionar; no concluyas que faltan "
        "controles a partir de una consulta fallida. La persona decide si sigue."
        + (f" El precio elegido lleva el cupón «{offer['coupon']}»"
           + (f" ({offer['list_price']} sin él)" if offer.get("list_price") else "")
           + ": aplícalo en la cesta antes de `purchase_check_cart`. Si la tienda ya no lo acepta y cobra más que "
           "el precio elegido, es otro precio: «BLOQUEADO: precio … — el cupón ya no se aplica»."
           if offer.get("coupon") else "")
    )


# How a saved card is filled, given by the plugin (vault_cards.prompt) so it reaches the errand,
# the only place that pays, instead of every chat's prompt.
card_rules: Callable[[str], str] = lambda profile: ""
# The person's saved delivery details (ask_person.load_details), by profile: None when the plugin
# cannot read them (then nothing is asked up front and the agent asks from the shop, as before).
details_block: Callable[[str], Optional[Dict[str, str]]] = lambda profile: None

# What a shop's checkout needs to deliver: asked once, all together, BEFORE the shop, and kept.
# An empty delivery form used to end as a generic «stuck» from inside the checkout.
DELIVERY_FIELDS = (
    ("name", "Nombre"), ("surname", "Apellidos"), ("address", "Dirección (calle y número)"),
    ("postcode", "Código postal"), ("city", "Localidad"), ("phone", "Teléfono"), ("email", "Email"),
)


def delivery_questions(details: Optional[Dict[str, str]]) -> List[Dict[str, Any]]:
    """The delivery details still missing, as one card of questions; empty when all are kept or
    when the details cannot be read."""
    if details is None:
        return []
    return [{"id": field, "question": label, "field": field, "choices": []}
            for field, label in DELIVERY_FIELDS if not str(details.get(field) or "").strip()]


def delivery_lines(details: Optional[Dict[str, str]]) -> str:
    known = [(label, str((details or {}).get(field) or "").strip()) for field, label in DELIVERY_FIELDS]
    known = [f"{label.split(' (')[0].lower()}: {value}" for label, value in known if value]
    return ("Datos de envío de la persona (úsalos tal cual, sin preguntarlos): " + "; ".join(known) + ". "
            if known else "")


def brief(entry: Dict[str, Any]) -> str:
    """The first message of an errand's session."""
    login = ("Antes de iniciar sesión, la persona quiere que se le pregunte: Hermes se lo pedirá."
             if entry.get("ask_before_login") else
             "Si la web pide iniciar sesión y hay un login guardado en el vault para ella, entra con "
             "`login_fill` sin preguntar y NUNCA crees una cuenta nueva teniendo ese acceso. Si no hay un acceso de ESTE origen, "
             "llama a `login_request` y termina el turno. Nunca uses accesos de otras tiendas. Para un código de verificación usa `login_request` con kind vault.code; se pide en el iPhone y el mismo recado continúa.")
    offer = entry.get("offer") if isinstance(entry.get("offer"), dict) else None
    try:
        delivery = delivery_lines(details_block(str(entry.get("profile") or "default")))
    except Exception:  # noqa: BLE001 — unreadable details: the agent asks from the shop
        delivery = ""
    prepared = entry.get("commerce") or {}
    if prepared.get("status") == "ready" and offer:
        # Reuse the connector cart; browser checks are still mandatory before approval.
        offer = {**offer, "channel": "catalog", "checkout_url": prepared["continue_url"]}
    what = (_offer_lines(offer) + " " + delivery if offer else
            "Pregunta con `ask_person` solo lo que cambia qué se hace o cuánto cuesta, todo en una sola vez "
            "y al principio. ")
    execution = (" En la página de la opción usa `purchase_browser` action=observe. Para preparar la cesta y "
           "el envío, una acción por vez con control_id y observation_id de la observación devuelta. "
           "Cada acción devuelve el estado real posterior: comprueba variante, unidades, errores y "
           "campos pendientes. No inventes selectores ni repitas un clic con resultado unchanged, stale "
           "o unknown. Si aún no hay pestaña propia, abre la URL de la opción con browser_exec y vuelve "
           "a observe. En controles especiales que no aparezcan, usa screenshot para observar antes "
           "del helper de navegador y verifica después. purchase_browser no introduce secretos ni paga. " if offer else "")
    return (
        f"[Recado de Alice] {entry['request']}\n\n"
        "Trabajas en segundo plano, fuera de cualquier chat: la persona no lee tus respuestas, ve la "
        "tarjeta del recado. Navegas en un contexto propio, sin sesiones iniciadas: si la web pide "
        "entrar, usa el login del vault. Hazlo de principio a fin tú: nunca llames a `errand_start` (ya estás en el "
        "recado). El comentario `#` con que empieza cada paso del navegador es lo que la persona ve: "
        "escríbelo en su idioma y en pocas palabras («Añadir al carrito», «Elegir envío»). "
        f"{login} {what}{execution}"
        "Si el acceso no se completa, lee el aviso concreto de la tienda. Rellenar campos no equivale a iniciar sesión. "
        "No afirmes que la tienda rechazó los datos sin un mensaje explícito que lo confirme. "
        "Un bloqueo de acceso se resuelve en la misma cuenta y cesta, no ofreciendo otros productos. "
        "Decide tú lo que tenga una opción razonable (tratamiento, envío estándar, sin extras, sin cuenta "
        "nueva si se puede comprar como invitado) y usa los datos de envío guardados. Antes del resumen, "
        "desmarca toda suscripción, prueba, renovación, seguro o extra que la tienda haya añadido sin que "
        "la persona lo pidiera (un «descuento con suscripción» no es el precio elegido) y nómbralo en el "
        "resumen si no se pudo quitar. Nunca preguntes por "
        "tarjetas: si una página de pago pide una y `browser_vault_list` no tiene ninguna para ella, llama "
        "a `card_request`. Tras añadir el formato y después de iniciar sesión, llama a `purchase_check_cart` para comprobar el precio real y las unidades de esta cesta antes de `checkout_request`. Cuando el pedido esté listo en el paso de pago, NO rellenes la tarjeta ni pulses pagar: "
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


def _default_home() -> Path:
    """The Hermes home (the root, not a profile's): where Alice keeps her files."""
    try:
        from hermes_constants import get_hermes_home

        home = Path(get_hermes_home())
    except Exception:  # noqa: BLE001
        home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return home.parent.parent if home.parent.name == "profiles" else home


def legacy_context_file(errand_id: str) -> Path:
    import tempfile

    # qa: allow temp-state — read once to move an older version's note to the Hermes home
    return Path(tempfile.gettempdir()) / CONTEXT_FILE.format(id=re.sub(r"[^a-f0-9]", "", errand_id))


def context_file(errand_id: str, home: Optional[Path] = None) -> Path:
    """Where an errand's browser context and tab are noted: under the Hermes home, private, so a
    reboot or a temp cleaner never takes it (it was in the system's temp folder). A note left in the
    old place by an earlier version is moved here the first time it is looked for."""
    folder = Path(home or _default_home()) / ".alice" / "errands"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = folder / (re.sub(r"[^a-f0-9]", "", errand_id) + ".ctx.json")
    legacy = legacy_context_file(errand_id)
    if not path.exists() and legacy.exists():
        try:
            os.replace(legacy, path)
        except OSError:
            pass
    return path


def context_lost(home: Path, errand_id: str) -> Optional[str]:
    """The browser context the errand was using is gone (Chrome closed or crashed, the note lost):
    a new one was made, empty. Nothing read in the old one stands — not the basket check, not the
    checkout evidence, not a login — so nothing can be paid on it. Returns the agent's note."""
    entry = get(home, errand_id)
    if entry is None:
        return None
    checkout = entry.get("checkout") if isinstance(entry.get("checkout"), dict) else None
    fields: Dict[str, Any] = {"cart_evidence": None, "checkout_evidence": None, "secure_answered": None}
    if checkout and checkout.get("status") == "pending":
        fields["checkout"] = {**checkout, "status": "replaced"}
        fields["status"] = "working" if entry.get("status") == "needs_approval" else entry.get("status")
    update(home, errand_id, **fields)
    paid = payment_pending(home, get(home, errand_id) or {})
    return ("\n\n[Alice] El navegador se reinició y la página de este recado se perdió: la cesta, el inicio de "
            "sesión y el resumen anteriores ya no valen. "
            + ("Ya se envió un pago o la persona lo aprobó: NO pagues; busca la confirmación en «Mis pedidos» o el "
               "correo y registra `purchase_outcome`." if paid else
               "Vuelve a la ficha del producto, añádelo, inicia sesión si hace falta, `purchase_check_cart` y "
               "`checkout_request` otra vez. No pagues hasta tener la nueva aprobación."))


def context_preamble(errand_id: str) -> str:
    """Code run before the errand's own: it switches the harness to the errand's tab in the
    errand's context, making both when missing. Stops the step if isolation fails."""
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
        with open(_path) as _file:
            _saved = _j.load(_file)
    except Exception:
        _saved = {{}}
    _lost = bool(_saved.get("context")) or bool(_saved.get("lost"))
    try:
        _targets = {{t.get("targetId") for t in cdp("Target.getTargets").get("targetInfos", [])}}
        if _saved.get("daemon") == _dpid and _saved.get("target") in _targets:
            _owned = cdp("Target.getTargetInfo", targetId=_saved["target"]).get("targetInfo") or {{}}
            if not _saved.get("context") or _owned.get("browserContextId") != _saved["context"]:
                raise RuntimeError("La pestaña guardada no pertenece al contexto del recado.")
            switch_tab(_saved["target"])
            cdp("Emulation.setFocusEmulationEnabled", enabled=True)
            return _saved
        _contexts = set(cdp("Target.getBrowserContexts").get("browserContextIds", []))
        _ctx = _saved.get("context") if _saved.get("context") in _contexts else None
        if _ctx is not None:
            _lost = bool(_saved.get("lost"))
        if _ctx is None:
            _ctx = cdp("Target.createBrowserContext").get("browserContextId")
        _tid = _saved.get("target") if (_saved.get("target") in _targets and _saved.get("context") == _ctx) else None
        if _tid is None:
            _tid = cdp("Target.createTarget", url="about:blank", browserContextId=_ctx, background=True).get("targetId")
        else:
            _owned = cdp("Target.getTargetInfo", targetId=_tid).get("targetInfo") or {{}}
            if _owned.get("browserContextId") != _ctx:
                raise RuntimeError("La pestaña guardada no pertenece al contexto del recado.")
        # alice: keep page transitions running without activating the macOS browser window.
        switch_tab(_tid)
        cdp("Emulation.setFocusEmulationEnabled", enabled=True)
        _saved = {{"context": _ctx, "target": _tid, "daemon": _dpid}}
        if _lost:
            # alice: the context noted before is gone; the plugin tells the agent nothing read there stands.
            _saved["lost"] = True
        with open(_path, "w") as _file:
            _j.dump(_saved, _file)
        return _saved
    except Exception as _e:
        raise RuntimeError("No se pudo aislar el navegador del recado; no se ejecutó el paso.") from _e
_alice_context = _alice_own_context()
del _alice_own_context
# alice: keep new pages and bank popups inside this errand's cookie context.
_alice_original_switch_tab = switch_tab
def switch_tab(target, activate=False):
    import json as _j
    _tid = (target.get("targetId") or target.get("target_id")) if isinstance(target, dict) else target
    _info = cdp("Target.getTargetInfo", targetId=_tid).get("targetInfo") or {{}}
    if _info.get("browserContextId") != _alice_context["context"]:
        raise RuntimeError("Esa pestaña no pertenece a este recado.")
    # Agent attachment is independent of desktop focus, even if a step asks to activate.
    _result = _alice_original_switch_tab(_tid, activate=False)
    cdp("Emulation.setFocusEmulationEnabled", enabled=True)
    _alice_context["target"] = _tid
    with open({path!r}, "w") as _file:
        _j.dump(_alice_context, _file)
    return _result
def ensure_real_tab():
    # alice: the shared helper can otherwise jump to another agent's real tab.
    switch_tab(_alice_context["target"])
    return current_tab()
# alice: clicks use CSS viewport coordinates, not document/screenshot dimensions.
if "click_at_xy" in globals() and not getattr(click_at_xy, "_alice_viewport_guard", False):
    _alice_original_click_at_xy = click_at_xy
    def click_at_xy(x, y, *args, **kwargs):
        import math as _math, json as _j
        try:
            _x, _y = float(x), float(y)
            _v = js("({{width:window.innerWidth,height:window.innerHeight}})")
            if isinstance(_v, str):
                _v = _j.loads(_v)
            _w, _h = float(_v["width"]), float(_v["height"])
        except Exception as _e:
            raise RuntimeError("No se pudo medir la zona visible; vuelve a inspeccionar antes de pulsar.") from _e
        if not all(_math.isfinite(n) for n in (_x, _y, _w, _h)) or _w <= 0 or _h <= 0:
            raise RuntimeError("Coordenadas o tamaño visible no válidos; vuelve a inspeccionar.")
        if not (0 <= _x < _w and 0 <= _y < _h):
            raise RuntimeError(f"El clic ({{_x}}, {{_y}}) queda fuera de la zona visible {{_w}} × {{_h}}. "
                               "Desplaza el elemento a la vista (también horizontalmente), vuelve a leer "
                               "su getBoundingClientRect y pulsa dentro de la zona visible. No repitas ese clic.")
        return _alice_original_click_at_xy(_x, _y, *args, **kwargs)
    click_at_xy._alice_viewport_guard = True
_alice_original_capture_screenshot = capture_screenshot
def capture_screenshot(*args, **kwargs):
    _path = _alice_original_capture_screenshot(*args, **kwargs)
    print(_path)
    return _path
def new_tab(url="about:blank"):
    _tid = cdp("Target.createTarget", url="about:blank",
               browserContextId=_alice_context["context"], background=True).get("targetId")
    switch_tab(_tid)
    if url != "about:blank":
        goto_url(url)
    return _tid
# alice: a page alert (alert, confirm, leave-page) freezes the page until it is answered.
# alice: an alert is acknowledged; a confirm is accepted only when asked, never when it orders.
def close_dialog(accept=False):
    import re as _re
    _info = page_info()
    _d = _info.get("dialog") if isinstance(_info, dict) else None
    if not _d:
        return None
    _kind = _d.get("type") or "alert"
    _pays = _re.search({PAY_WORDS.pattern!r}, str(_d.get("message") or ""), _re.I)
    _yes = _kind in ("alert", "beforeunload") or (bool(accept) and _kind == "confirm" and not _pays)
    cdp("Page.handleJavaScriptDialog", accept=_yes)
    return {{"closed": _kind, "accepted": _yes, "message": str(_d.get("message") or "")[:200]}}
try:
    _alice_closed = close_dialog()
    if _alice_closed:
        print("[alice] Alerta de la página cerrada:", _alice_closed)
except Exception:
    pass
"""


def _cdp_root(home: Optional[Path]) -> str:
    """Alice's browser as configured (any port), else Chrome's usual debugging port."""
    try:
        import importlib.util
        import sys as _sys

        name = "alice_browser_live"
        if name not in _sys.modules:
            spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("browser_live.py"))
            _sys.modules[name] = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(_sys.modules[name])
        configured = _sys.modules[name].configured_url(Path(home or _default_home()))
        if configured:
            parts = urlsplit(configured if "://" in configured else "http://" + configured)
            return f"http://{parts.netloc}"
    except Exception:  # noqa: BLE001
        pass
    return "http://127.0.0.1:9222"  # qa: allow fixed-port — Chrome's own default when Alice configured none


def release_context(errand_id: str, browser_ws: Optional[str] = None, home: Optional[Path] = None) -> bool:
    """The errand is over: its browser context (and its pages) is closed, its note removed."""
    path = context_file(errand_id, home)
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
            with urllib.request.urlopen(_cdp_root(home) + "/json/version", timeout=2) as response:  # noqa: S310
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

    def start(self, session_id: str, text: str, *, model: str, provider: str) -> str:
        out = self._call("POST", "/v1/runs", {"input": text, "session_id": session_id,
                                               "model": model, "provider": provider})
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
        except Exception:  # noqa: BLE001 — the errand's checkout is already revoked; the run is told later
            logging.getLogger(__name__).warning("errands: could not stop run %s", run_id, exc_info=True)


# ── Driving an errand ───────────────────────────────────────────────────────────

FINISHED = ("completed", "failed", "cancelled", "interrupted")


def page_of(url: str) -> str:
    """A page without its query: the same checkout step whatever its tokens."""
    parts = urlsplit(str(url or ""))
    return f"{parts.netloc}{parts.path}".rstrip("/")


def circling(entry: Dict[str, Any]) -> Optional[str]:
    """The page an errand keeps going round on without getting past, or None. Steps before the
    last warning (``circle_from``) do not count again."""
    observed = entry.get("browser_observation")
    if isinstance(observed, dict):
        # A one-page checkout changes fields, delivery, errors and totals without
        # changing its URL. DOM progress, not the agent's comments, is decisive.
        if time.time() - float(observed.get("progress_at") or 0) < CIRCLE_SECONDS:
            return None
        if int(observed.get("unchanged") or 0) < CIRCLE_STEPS:
            return None
        if observed.get("url"):
            return page_of(observed["url"])
    since = float(entry.get("circle_from") or 0)
    steps = [s for s in entry.get("steps") or [] if s.get("url") and float(s.get("at") or 0) > since]
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
    if entry.get("offer"):
        return  # The purchase controller owns continuations; no gateway auxiliary goal.
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
                 sleep: Callable[[float], None] = time.sleep,
                 page_signature: Optional[Callable[[Dict[str, Any]], Optional[str]]] = None):
        self.home = Path(home)
        self.errand_id = errand_id
        self.page_signature = page_signature or _page_signature
        entry = get(self.home, errand_id) or {}
        # Older errands predate the fixed model. Save the selected route before their next
        # run, so answers, approvals and service restarts keep using that same selection.
        if entry and not entry.get("model") and not entry.get("provider"):
            entry = update(self.home, errand_id, **model_selection(self.home)) or entry
        if entry and (not entry.get("model") or not entry.get("provider")):
            raise ValueError("El recado no tiene un modelo y proveedor válidos.")
        self.gateway = gateway or Gateway(self.home, entry.get("profile") or "")
        # A purchase is controlled by checkout/receipt states, not an auxiliary provider.
        # Injected judges remain supported for other errands and fixture tests.
        self.judge = judge or (self._purchase_decision if entry.get("offer") else self._judge)
        if entry.get("offer") and judge is None:
            # Purchases saved before this controller can still carry an active Hermes goal.
            # Clear that auxiliary loop too, without changing this errand's browser or model.
            _goal_manager(entry["session_id"]).clear()
        self.sleep = sleep

    @staticmethod
    def _purchase_decision(session_id: str, reply: str) -> Dict[str, Any]:
        # Receipt outcomes and waiting/approval states are checked by run() first.
        # Page repetition and run limits still bound work; prose cannot prove a payment.
        return {"status":"active", "should_continue":True, "continuation_prompt":CONTINUATION}

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

    def _request_access(self, entry: Dict[str, Any]) -> bool:
        """A wait for secure access, never another agent run or payment retry."""
        if (entry.get("login_declined") or payment_pending(self.home, entry)
                or (entry.get("receipt") or {}).get("outcome") == "paid"):
            return False
        from importlib.util import spec_from_file_location, module_from_spec
        import sys
        name = "alice_errand_access"
        if name not in sys.modules:
            spec = spec_from_file_location(name, Path(__file__).with_name("errand_access.py"))
            sys.modules[name] = module_from_spec(spec)
            spec.loader.exec_module(sys.modules[name])
        sys.modules[name].request(self.home, self.errand_id, replace=bool(
            entry.get("login_attempt") or (entry.get("saved_login") or {}).get("handle")))
        return True

    def _stuck(self, reason: str, **fields: Any) -> str:
        """Leaves the errand stuck. If a payment may be out with no known outcome, that comes first:
        the ledger and the receipt say «unknown», the card never says nothing was paid."""
        if close_unknown(self.home, self.errand_id):
            reason = _clean(UNKNOWN_REASON + " (" + str(reason).rstrip(".") + ")", 400)
        update(self.home, self.errand_id, status="stuck", reason=reason, **fields)
        return "stuck"

    def _wait_for_browser(self) -> bool:
        """While the person holds the shared browser, the errand does not start another run: two
        hands on one page paid twice once. The lease lapses on its own when forgotten."""
        waited = False
        while _browser_held(self.home):
            if self._entry().get("status") != "working":
                break
            waited = True
            self.sleep(5)
        return waited

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
        # The controller, never the model, chooses the connector from stored quote evidence.
        if entry.get("offer") and not int(entry.get("runs") or 0):
            from importlib.util import spec_from_file_location, module_from_spec
            import sys
            name = "alice_purchase_connectors"
            if name not in sys.modules:
                spec = spec_from_file_location(name, Path(__file__).with_name("purchase_connectors.py"))
                sys.modules[name] = module_from_spec(spec)
                spec.loader.exec_module(sys.modules[name])
            sys.modules[name].prepare(self.home, self.errand_id)
            entry = self._entry()
        # The first run reads the brief; an answer to the questions asked before the shop (the
        # delivery details) comes with it, never instead of it.
        text = (brief(entry) + "\n\n" + message) if message and not int(entry.get("runs") or 0) \
            and not message.startswith(CONTINUATION) else (message or brief(entry))
        previous = ""
        repeat_recoveries = 0
        self_fixed = False
        went_cheaper = False
        coupon_pushed = False
        stalls = 0
        judge_failures = 0
        outcome_asked = 0
        # Restarted while its last run still goes on in the gateway: that run finishes first,
        # never a second one beside it in the same session.
        if entry.get("run_id") and message:
            try:
                still = str(self.gateway.status(entry["run_id"]).get("status") or "")
            except Exception:  # noqa: BLE001 — gone or unreachable: nothing to wait for
                still = ""
            if still in ("running", "waiting_for_approval", "queued"):
                # The person's answer (an approval, a card) is what the agent must hear next, not a
                # bare «continue»; only a restart's own note gives way to it.
                self._wait_run(entry["run_id"])
                if message.startswith(CONTINUATION):
                    text = CONTINUATION
        while True:
            entry = self._entry()
            if entry.get("status") != "working":
                return entry.get("status", "missing")
            if int(entry.get("runs") or 0) >= MAX_RUNS:
                return self._stuck("Ha usado todos sus intentos sin terminar.")
            waited = self._wait_for_browser()
            if waited:
                entry = self._entry()
                if entry.get("status") != "working":
                    return entry.get("status", "missing")
                if entry.get("resume_message"):
                    text = entry["resume_message"]
                    update(self.home, self.errand_id, resume_message=None)
            try:
                if not prepare_browser(self.home):
                    raise RuntimeError("Browser not ready")
            except Exception:
                return self._stuck("El navegador de Alice no pudo arrancar; no se ha ejecutado el recado. Puedes reintentarlo.")
            try:
                steps_before = entry.get("steps") or []
                run_id = self.gateway.start(entry["session_id"], text,
                                            model=entry["model"], provider=entry["provider"])
            except Exception as exc:  # noqa: BLE001
                return self._stuck(f"No se pudo hablar con Hermes: {type(exc).__name__}.")
            update(self.home, self.errand_id, run_id=run_id, runs=int(entry.get("runs") or 0) + 1)
            state = self._wait_run(run_id)
            reply = _clean(state.get("output") or "", 2000)
            entry = self._entry()
            if reply:
                update(self.home, self.errand_id, summary=reply[:300])
            if entry.get("status") != "working":
                return entry.get("status", "missing")
            if entry.get("resume_message"):
                text = entry["resume_message"]
                update(self.home, self.errand_id, resume_message=None)
                continue
            try:
                from importlib.util import spec_from_file_location, module_from_spec
                import sys
                name = "alice_errand_access"
                if name not in sys.modules:
                    spec = spec_from_file_location(name, Path(__file__).with_name("errand_access.py"))
                    sys.modules[name] = module_from_spec(spec)
                    spec.loader.exec_module(sys.modules[name])
                if sys.modules[name].detect_pending(self.home,self.errand_id):
                    return "needs_login"
            except Exception:
                pass  # Unreadable DOM is handled by the ordinary recovery/judge path.
            if state.get("status") == "circling":
                # The page's state, not its address: on Prozis, login, address and payment all
                # live at checkout/index. Only the same page saying the same thing twice is a loop.
                signature = self.page_signature(entry)
                if entry.get("circle_page") != state.get("page") or (signature and signature != entry.get("circle_hash")):
                    # One-page checkouts take many steps on one path while moving on: the first
                    # round on a page is a word to the agent, not a stop.
                    update(self.home, self.errand_id, circle_from=time.time(), circle_page=state.get("page"),
                           circle_hash=signature)
                    text = (CONTINUATION + " Llevas muchos pasos en la misma página (" + str(state.get("page"))[:80]
                            + "). Si la tienda rechaza algo, lee su mensaje de error antes de volver a intentarlo; "
                            "si estás avanzando (dirección, envío, pago en una misma página), sigue y di en qué paso estás.")
                    continue
                return self._stuck(
                    "Lleva varios minutos en la misma página sin poder avanzar (" + str(state.get("page"))[:80]
                    + "). Ábrela en el navegador para ver qué pide la tienda.")
            if state.get("status") == "stalled":
                stalls += 1
                if stalls >= 2:
                    return self._stuck("El modelo dejó de responder dos veces seguidas.")
                text = (CONTINUATION + " El paso anterior se quedó colgado: mira en qué punto está la "
                        "página y sigue desde ahí.")
                continue
            if state.get("status") == "failed":
                exit_reason = str(state.get("turn_exit_reason") or "")
                exhausted = exit_reason.startswith("max_iterations_reached")
                update(self.home, self.errand_id, last_run_failure={
                    "kind": "iteration_limit" if exhausted else "runtime", "run_id": run_id})
                # Hermes marks an exhausted turn failed even when its output identifies a
                # recoverable access wall. Route to a secure wait without more LLM iterations.
                if exhausted and blocked_by(reply, entry.get("offer"))["kind"] == "access":
                    try:
                        if self._request_access(entry):
                            return "needs_login"
                    except ValueError as exc:
                        if getattr(exc, "access_already_provided", False):
                            return self._stuck(str(exc), blocked={"kind": "access"})
                    except Exception:
                        pass  # Origin/context unavailable: keep the access block, never leak secrets.
                    return self._stuck("El agente agotó el límite de pasos sin resolver el acceso a la tienda.",
                                       blocked={"kind": "access"})
                return self._stuck(_clean(state.get("error") or (
                    "El agente agotó el límite de pasos sin completar la compra." if exhausted else
                    "El agente falló."), 200))
            # The chosen option cannot be bought as chosen (gone, another price): it stops here
            # and says why, instead of buying something else.
            if BLOCKED.match(reply):
                said = _clean(BLOCKED.sub("", reply, count=1), 300) or "La opción elegida ya no se puede comprar."
                blocked = blocked_by(said, entry.get("offer"))
                if blocked["kind"] == "other" and entry.get("login_declined") and re.search(
                        r"iniciar sesi[oó]n|sign.?in|log.?in|exige.*cuenta|requires.*account", said, re.I):
                    blocked = {"kind": "access"}
                    update(self.home, self.errand_id, guest_failed=True)
                if blocked["kind"] == "access" and not entry.get("login_declined"):
                    # The model may report an access wall even with filled fields. The
                    # controller asks securely; it does not treat filled as authenticated.
                    try:
                        if self._request_access(entry):
                            return "needs_login"
                    except ValueError as exc:
                        if getattr(exc, "access_already_provided", False):
                            return self._stuck(str(exc), blocked={"kind": "access"})
                        if not self_fixed:
                            self_fixed = True
                            text = CONTINUATION + " Resuelve el acceso, sin detener la compra: " + str(exc) + " Si el acceso falla, login_request con replace=true. Termina el turno cuando la tarjeta segura esté pendiente."
                            continue
                    except Exception:
                        pass  # Cannot verify the page/origin: preserve the explicit access block.
                if blocked["kind"] == "cheaper" and not went_cheaper:
                    # The shop asks less than the option chosen (a coupon or a sale the card already
                    # promised): the person's choice only got better. It goes on at that price; the
                    # final total is still approved before anything is paid.
                    went_cheaper = True
                    offer = entry.get("offer") if isinstance(entry.get("offer"), dict) else {}
                    update(self.home, self.errand_id, offer={**offer, "price": blocked["price"]})
                    text = (CONTINUATION + f" La tienda cobra {blocked['price']}, menos que los {offer.get('price')} "
                            "elegidos: no es un motivo para parar. Sigue con esa misma opción a ese precio, añádela "
                            "a la cesta, comprueba el total con `purchase_check_cart` y llega hasta `checkout_request`. "
                            "Menciona la diferencia en el resumen final.")
                    continue
                if blocked["kind"] == "cheaper":
                    blocked = {"kind": "other"}
                offer_now = entry.get("offer") if isinstance(entry.get("offer"), dict) else {}
                if blocked["kind"] == "price" and offer_now.get("coupon") and not coupon_pushed:
                    # A coupon price chosen and a higher basket: the coupon goes in before anyone is
                    # asked to accept a price. The agent gave up without trying it (06-10).
                    coupon_pushed = True
                    text = (CONTINUATION + f" La cesta marca {blocked['price']} porque aún no tiene el cupón "
                            f"{offer_now['coupon']}: no es un cambio de precio. Abre la cesta o el checkout, "
                            "escribe el cupón en su campo de código promocional, aplícalo, espera a que cambie el "
                            "total y llama a `purchase_check_cart`. Si solo lo acepta con la sesión iniciada, inicia sesión con "
                            "`login_fill` y el acceso guardado y vuelve a aplicarlo. Solo si la tienda rechaza el cupón, termina "
                            "con «BLOQUEADO: precio … — la tienda no acepta el cupón».")
                    continue
                if blocked["kind"] == "datum":
                    # A datum only the person has (date of birth, ID number): one question in the
                    # errand's card, kept for every later purchase; the errand goes on with it.
                    ask_datum(self.home, self.errand_id, blocked)
                    return "needs_input"
                # Only what the person must decide stops the errand: another price, or the option gone.
                # A basket with something else in it, a wrong variant, a page error is the agent's to
                # fix: one checkout stopped on «contains another product» left over from an earlier try.
                if blocked["kind"] == "other" and not self_fixed:
                    self_fixed = True
                    text = (CONTINUATION + " Eso lo resuelves tú, sin contárselo a la persona: " + said + " "
                            "Si la cesta tiene artículos que no son la opción elegida (de intentos anteriores), "
                            "quítalos; corrige variante y cantidad; recarga o vuelve a la ficha si la página falla. "
                            "El precio tachado es el precio anterior, no un cambio del precio elegido. Si el precio actual "
                            "coincide con el elegido, añade el producto y comprueba el total en la cesta; no pidas aceptar "
                            "el mismo precio. Luego sigue hasta el paso de pago y llama a `checkout_request`. Solo si la tienda ya "
                            "no vende esa opción o cobra más, termina con «BLOQUEADO: …».")
                    continue
                return self._stuck(said, blocked=blocked)
            receipt = entry.get("receipt") or {}
            if receipt.get("outcome") in ("paid", "declined", "not_charged"):
                # Known how it ended: the person reads the result. A declined payment is not a
                # reason to try again on its own.
                update(self.home, self.errand_id, status="done")
                return "done"
            if receipt.get("outcome") == "unknown":
                # Said as unknown: the errand stops on it and the person checks before anything
                # is paid again (the ledger refuses it meanwhile).
                return self._stuck(UNKNOWN_REASON)
            # Similar summaries are not a loop when the browser has recorded
            # new steps. Give a real no-progress loop one bounded recovery.
            if previous and repeats(previous, reply) and (entry.get("steps") or []) == steps_before:
                if repeat_recoveries >= 1:
                    last = (entry.get("steps") or [{}])[-1].get("text") or "sin pasos registrados"
                    return self._stuck(
                        "No ha podido avanzar tras un intento de recuperación. Último paso: " + str(last)[:140] + ".")
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
                judge_failures = 0
            except Exception:  # noqa: BLE001 — a judge that cannot answer lets the agent go on once
                judge_failures += 1
                if judge_failures >= 2:
                    return self._stuck("Hermes no pudo juzgar el recado dos veces seguidas.")
                decision = {"should_continue": True, "continuation_prompt": CONTINUATION}
            if decision.get("status") == "done":
                if payment_pending(self.home, entry):
                    # Money may be out: «done» is not accepted without the outcome written down.
                    # Asked twice; then it ends as unknown, which the person reads as such.
                    outcome_asked += 1
                    if outcome_asked <= 2:
                        text = (CONTINUATION + " Se envió un pago, o la persona aprobó pagar, y no has registrado "
                                "cómo acabó. Mira la página de confirmación, «Mis pedidos» en la tienda o el correo "
                                "del pedido y llama a `purchase_outcome` (paid con el número de pedido, declined, "
                                "not_charged, o unknown si no lo ves). No vuelvas a pagar.")
                        continue
                    return self._stuck(UNKNOWN_REASON)
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
            return self._stuck(_clean(decision.get("reason") or decision.get("message") or "Se ha atascado.", 200))


def _browser_held(home: Path) -> bool:
    try:
        import importlib.util
        import sys as _sys

        name = "alice_browser_live"
        if name not in _sys.modules:
            spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("browser_live.py"))
            _sys.modules[name] = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(_sys.modules[name])
        live = _sys.modules[name]
        return bool(live.managed(home)) and live.control(home)["holder"] == "human"
    except Exception:  # noqa: BLE001 — unknown is not held: the browser tool's own gate still waits
        return False


def handed_back(home: Path, now: Optional[float] = None) -> List[str]:
    """The person gives the browser back. What they did there is not known: on an errand whose
    checkout they approved they may have paid, so that is written in the ledger first (a second
    payment is then refused until its outcome is read), and every errand under way is told to read
    the page again before doing anything. Returns the errands told."""
    told = []
    for entry in listing(home):
        if entry.get("status") not in ACTIVE:
            continue
        approved = (isinstance(entry.get("checkout"), dict) and entry["checkout"].get("status") == "approved"
                    and not isinstance(entry.get("receipt"), dict))
        if approved:
            try:
                _purchases().record(home, entry["checkout"].get("site") or entry.get("site") or "", entry.get("session_id") or "",
                                    now=now)
            except Exception:  # noqa: BLE001
                pass
            message = (CONTINUATION + " La persona tuvo el navegador y te lo devuelve. Puede haber pagado ella: relee la "
                       "página; si ves una confirmación de pedido, registra `purchase_outcome`; si no, mira «Mis pedidos» "
                       "o el correo antes de nada. No vuelvas a pagar sin saberlo.")
        else:
            message = (CONTINUATION + " La persona tuvo el navegador y te lo devuelve: relee la página (puede haber "
                       "cambiado algo) y sigue desde ahí.")
        if entry.get("status") == "working":
            # A waiting errand hears the person's own answer next; this note is for one under way.
            update(home, entry["id"], resume_message=message)
            told.append(entry["id"])
    return told


def sweep(home: Path, now: Optional[float] = None) -> Dict[str, List[str]]:
    """What keeps errands honest when nobody is looking: stale checkouts expire, forgotten pages
    close, stops about a datum become the question, and errands left working by a restart go on.
    Each part runs on its own: one failing never stops the others."""
    done: Dict[str, List[str]] = {}
    for name, work in (("expired", lambda: expire_checkouts(home, now)), ("released", lambda: release_stale(home, now)),
                       ("asked", lambda: convert_datum_stops(home)), ("resumed", lambda: ensure_running(home))):
        try:
            done[name] = work() or []
        except Exception:  # noqa: BLE001
            done[name] = []
    return done


_sweeper: Dict[str, threading.Thread] = {}


def start_sweeper(home: Path, every: float = 60.0) -> bool:
    """Runs ``sweep`` every minute in this process, once per home."""
    key = str(Path(home).resolve())
    with _threads_lock:
        if key in _sweeper and _sweeper[key].is_alive():
            return False

        def loop():
            while True:
                time.sleep(every)
                sweep(Path(home))

        thread = threading.Thread(target=loop, name="alice-errand-sweeper", daemon=True)
        _sweeper[key] = thread
    thread.start()
    return True


_threads: Dict[str, threading.Thread] = {}
_threads_lock = threading.Lock()


def prepare_browser(home: Path) -> bool:
    """Bring the managed browser up before spending a model run, also after a restart."""
    import importlib.util
    import sys

    name = "alice_browser_live"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("browser_live.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name].ensure(home)


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
            pending = (get(home, errand_id) or {}).get("resume_message")
            if pending:
                update(home, errand_id, resume_message=None)
            final = (engine_factory or Engine)(home, errand_id).run(pending or message)
            # A stuck errand keeps its page: its card says «open the browser to see what the shop
            # asks», and «Seguir desde aquí» goes on from that basket. release_stale sweeps it later.
            if final in ("done", "denied", "stopped", "missing"):
                release_context(errand_id, home=home)
        except Exception as exc:  # noqa: BLE001 — never raised in a thread; the errand says what happened
            reason = f"Error interno: {type(exc).__name__}."
            try:
                if close_unknown(home, errand_id):
                    reason = UNKNOWN_REASON + " (" + reason.rstrip(".") + ")"
            except Exception:  # noqa: BLE001
                pass
            update(home, errand_id, status="stuck", reason=reason)
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


STALE_CONTEXT = 2 * 3600
# An errand waiting for the person this long has its page closed too; when they answer, the
# errand starts its basket again (context_lost) rather than keeping a tab open for days.
STALE_WAITING = 12 * 3600


def release_stale(home: Path, now: Optional[float] = None) -> List[str]:
    """The browser pages of errands stuck (or waiting) for hours are closed; the person has moved on."""
    now = now or time.time()
    released = []
    for entry in listing(home):
        age = now - float(entry.get("updated_at") or 0)
        waiting = entry.get("status") in ("needs_approval", "needs_input", "needs_card", "needs_login")
        if (not entry.get("context_released")
                and ((entry.get("status") == "stuck" and age > STALE_CONTEXT) or (waiting and age > STALE_WAITING))
                and not (waiting and isinstance(entry.get("checkout"), dict) and entry["checkout"].get("status") == "approved")):
            release_context(entry["id"], home=home)
            update(home, entry["id"], now=entry.get("updated_at"), context_released=True)
            released.append(entry["id"])
    return released


def _page_signature(entry: Dict[str, Any]) -> Optional[str]:
    """What the errand's page says now (title and visible text), hashed; None when unreadable."""
    try:
        import hashlib
        import importlib.util
        import sys

        name = "alice_errand_access"
        if name not in sys.modules:
            spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name("errand_access.py"))
            sys.modules[name] = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(sys.modules[name])
        access = sys.modules[name]
        _origin, context, _ = access.target(entry)
        text = access.page_evaluate(context, "document.title + '\\n' + (document.body ? document.body.innerText : '').slice(0, 6000)")
        return hashlib.sha256(" ".join(str(text or "").split()).encode("utf-8")).hexdigest()
    except Exception:  # noqa: BLE001
        return None


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
                           ask_before_login=bool(args.get("ask_before_login")), now=now, offer=offer,
                           model_route=model_selection(home))
        entries = [e for e in entries if e.get("status") in ACTIVE
                   or now - float(e.get("updated_at") or 0) < KEEP]
        entries.append(entry)
        _write(path, entries)
    try:
        open_goal(entry)
        missing = delivery_questions(details_block(profile or "default")) if offer else []
        if missing:
            # Asked once, all together, before a single page is opened: the shop will need them,
            # and an empty address form inside the checkout ended as a generic stop.
            entry = update(home, entry["id"], status="needs_input",
                           questions={"title": "Datos de envío", "items": missing, "fields": True})
        else:
            launch(home, entry["id"])
    except Exception as exc:
        # A retry must not rediscover a supposedly working errand that never started.
        update(home, entry["id"], status="stuck", reason=f"No pudo iniciarse: {type(exc).__name__}.")
        raise
    return started_result(entry)


def started_result(entry: Dict[str, Any]) -> Dict[str, Any]:
    """The existing errand's identity and actual state, also used by the chat's tool."""
    return {"errand_id": entry["id"], "title": entry["title"], "status": entry["status"],
            "next": "Report this errand's actual status in one short line. Alice shows its progress. "
                    "Do not start another or do it here."}


def resume(home: Path, errand_id: str, message: str) -> bool:
    """The person answered (approval, a question): the goal leaves its wait and the errand goes on.

    The message is kept on the errand too: when its engine is still driving the run in which the
    agent asked (the model had not ended its turn yet), ``launch`` cannot start another and the
    running engine reads ``resume_message`` as the next thing to send. An approval given quickly
    once arrived nowhere and the agent asked for it again."""
    entry = update(home, errand_id, status="working", questions=None, approval=None, resume_message=message)
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
    if entry.get("status") not in ACTIVE + ("stuck",):
        return entry
    checkout = entry.get("checkout")
    fields: Dict[str, Any] = {}
    if isinstance(checkout, dict) and checkout.get("status") in ("pending", "approved"):
        # Stopped means nothing is paid, even if a tool call is already on its way.
        fields["checkout"] = {**checkout, "status": "revoked"}
    entry = update(home, errand_id, status="stopped", reason="El recado se ha detenido.", secure_request=None,
                   resume_message=None, **fields)
    try:
        _goal_manager(entry["session_id"]).clear()
    except Exception:
        pass
    if entry.get("run_id"):
        Gateway(home, entry.get("profile") or "").stop(entry["run_id"])
    release_context(errand_id, home=home)
    return entry


def public(entry: Dict[str, Any]) -> Dict[str, Any]:
    """What Alice shows: everything but the internal session wiring."""
    # The chat it came from stays: Alice finds an errand's cards by it when the chat's reply
    # never called errand_start (the plugin starts it anyway).
    hidden = {"run_id", "resume_message", "secure_answered", "cart_evidence", "checkout_evidence", "circle_from",
              "circle_page", "circle_hash", "pay_again_until", "answered", "browser_observation"}
    out = {k: v for k, v in entry.items() if k not in hidden}
    if isinstance(out.get("approval"), dict):
        out["approval"] = {k: v for k, v in out["approval"].items() if k != "run_id"}
    try:
        if out.get("status") == "stuck" and access_blocked(entry):
            out["blocked"] = {"kind": "access"}
    except Exception:  # noqa: BLE001 — one unreadable reason must not hide every purchase from the phone
        pass
    if isinstance(out.get("secure_request"), dict):
        out["secure_request"] = {k: v for k, v in out["secure_request"].items() if k not in ("context", "target")}
    # Only the owned page target is public; cookies, browser context and secrets stay private.
    try:
        context = json.loads(context_file(entry["id"]).read_text())
        if isinstance(context.get("target"), str) and context.get("context"):
            out["browser_target"] = context["target"]
    except (OSError, ValueError, KeyError):
        pass
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
