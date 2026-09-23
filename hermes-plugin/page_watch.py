"""Pages watched for someone: a price that drops, stock that comes back, a text that appears.

The watching is changedetection.io (Apache-2.0), installed on first use into its own
virtualenv under ``<hermes home>/alice/changedetection`` and run on loopback only. It knows
how to read a product page's price and stock (the ``restock_diff`` processor) and checks each
page on its own schedule, with no model involved.

Alice keeps what each watch is *for* — the threshold, the text to look for — in
``<hermes home>/.alice/watches.json``, and decides when something is news: a price at or
under the threshold, stock back, the text there, the page changed. A Hermes routine runs a
script every few minutes; the script prints only news, and a routine whose script prints
nothing never wakes the model. So a watch costs nothing until there is something to say.
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit

PORT = 5057
BASE = f"http://127.0.0.1:{PORT}"
HOME_DIR = Path("alice") / "changedetection"
META = Path(".alice") / "watches.json"
KINDS = ("price", "stock", "change", "text")
ROUTINE = "Vigilancias"
SCRIPT = "alice_vigilancias.py"
WATCH_PACKAGE = "changedetection.io==0.60.7"
ROUTINE_PROMPT = (
    "Son novedades de páginas que la persona te pidió vigilar. Avísale en pocas líneas: una por "
    "vigilancia, con el enlace [nombre](url) y lo nuevo (precio, stock o cambio) y qué significa "
    "para ella. Si una página ya no se puede leer, dilo y ofrece borrar la vigilancia. Sin saludos "
    "ni despedidas. No uses herramientas: todo lo que necesitas está abajo."
)


class WatchError(Exception):
    pass


# ── Installing and running changedetection.io ───────────────────────────────────


def _dir(root: Path) -> Path:
    return Path(root) / HOME_DIR


def _binary(root: Path) -> Path:
    return _dir(root) / "venv" / "bin" / "changedetection.io"


def installed(root: Path) -> bool:
    return _binary(root).is_file()


def _install_state(root: Path) -> Dict[str, Any]:
    try:
        return json.loads((_dir(root) / "install.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _set_install_state(root: Path, **state: Any) -> None:
    _dir(root).mkdir(parents=True, exist_ok=True)
    (_dir(root) / "install.json").write_text(json.dumps({**state, "at": time.time()}), encoding="utf-8")


_installing = threading.Lock()


def install(root: Path, python: str = sys.executable) -> None:
    """Its own virtualenv and a versioned watcher; a minute or two."""
    if not _installing.acquire(blocking=False):
        return
    try:
        _set_install_state(root, state="installing")
        venv = _dir(root) / "venv"
        subprocess.run([python, "-m", "venv", str(venv)], check=True, capture_output=True, timeout=300)
        pip = str(venv / "bin" / "pip")
        subprocess.run([pip, "install", "--quiet", "--upgrade", "pip"], capture_output=True, timeout=600)
        done = subprocess.run([pip, "install", "--quiet", WATCH_PACKAGE], capture_output=True,
                              text=True, timeout=1800)
        if done.returncode != 0 or not installed(root):
            _set_install_state(root, state="failed", error=(done.stderr or "")[-400:])
            return
        _set_install_state(root, state="done")
    except Exception as exc:  # noqa: BLE001 — the phone shows it
        _set_install_state(root, state="failed", error=str(exc)[-400:])
    finally:
        _installing.release()


def running() -> bool:
    try:
        with urllib.request.urlopen(BASE + "/", timeout=2) as response:  # noqa: S310 — loopback
            return response.status < 500
    except Exception:
        return False


def start(root: Path, wait: float = 40.0) -> bool:
    if running():
        return True
    if not installed(root):
        return False
    data = _dir(root) / "data"
    data.mkdir(parents=True, exist_ok=True)
    log = open(_dir(root) / "run.log", "ab")  # noqa: SIM115 — handed to the child
    environment = {**os.environ, "ALLOW_IANA_RESTRICTED_ADDRESSES": "false", "ALLOW_FILE_URI": "false",
                   "DISABLE_VERSION_CHECK": "true", "LLM_FEATURES_DISABLED": "true"}
    subprocess.Popen(  # noqa: S603 — our own venv's launcher, fixed flags
        [str(_binary(root)), "-h", "127.0.0.1", "-p", str(PORT), "-d", str(data), "-C", "-l", "WARNING"],
        stdout=log, stderr=log, start_new_session=True, cwd=str(_dir(root)), env=environment)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if running():
            return True
        time.sleep(0.5)
    return False


def _key(root: Path) -> str:
    try:
        data = json.loads((_dir(root) / "data" / "changedetection.json").read_text(encoding="utf-8"))
        return str(data["settings"]["application"]["api_access_token"])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise WatchError("La vigilancia de páginas aún no ha arrancado.") from exc


def _api(root: Path, method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Any:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(BASE + "/api/v1" + path, data=data, method=method,
                                     headers={"x-api-key": _key(root), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:  # noqa: S310 — loopback
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise WatchError(f"La vigilancia de páginas respondió {exc.code}.") from exc
    except OSError as exc:
        raise WatchError("La vigilancia de páginas no responde.") from exc
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode("utf-8", "replace")


# ── What each watch is for ───────────────────────────────────────────────────────


def _meta(root: Path) -> Dict[str, Dict[str, Any]]:
    try:
        data = json.loads((Path(root) / META).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_meta(root: Path, meta: Dict[str, Dict[str, Any]]) -> None:
    path = Path(root) / META
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(meta, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(temp, path)


def _public(url: str) -> str:
    """Only public web pages: a watch must never become a way to read this machine."""
    raw = (url or "").strip()
    parts = urlsplit(raw)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password:
        raise WatchError("Solo se pueden vigilar páginas web públicas (http o https).")
    try:
        port = parts.port
    except ValueError as exc:
        raise WatchError("La dirección no es válida.") from exc
    if port not in (None, 80, 443):
        raise WatchError("Solo se vigilan páginas en los puertos web normales.")
    host = parts.hostname.lower().rstrip(".")
    if host == "localhost" or host.endswith((".local", ".localhost", ".internal")):
        raise WatchError("Esa dirección no es pública.")
    try:
        addresses = {info[4][0] for info in socket.getaddrinfo(host, port or 443, proto=socket.IPPROTO_TCP)}
    except OSError as exc:
        raise WatchError("No encuentro esa página.") from exc
    for address in addresses:
        ip = ipaddress.ip_address(address.split("%")[0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast \
                or ip.is_unspecified:
            raise WatchError("Esa dirección no es pública.")
    return raw


def create(root: Path, *, url: str, kind: str, label: str = "", below: Optional[float] = None,
           text: str = "", every_minutes: int = 60, profile: str = "default") -> Dict[str, Any]:
    if kind not in KINDS:
        raise WatchError("El tipo de vigilancia debe ser price, stock, change o text.")
    if kind == "text" and not text.strip():
        raise WatchError("Falta el texto que hay que esperar.")
    if below is not None and below <= 0:
        raise WatchError("El precio límite tiene que ser mayor que cero.")
    url = _public(url)
    if not start(root):
        raise WatchError("La vigilancia de páginas no está instalada. Actívala en Alice › Vigilancias.")
    minutes = max(15, min(int(every_minutes or 60), 24 * 60))
    body = {"url": url, "title": (label or "").strip()[:120] or None,
            "processor": "restock_diff" if kind in ("price", "stock") else "text_json_diff",
            "time_between_check_use_default": False, "time_between_check": {"minutes": minutes}}
    made = _api(root, "POST", "/watch", {k: v for k, v in body.items() if v is not None})
    uuid = (made or {}).get("uuid") if isinstance(made, dict) else None
    if not uuid:
        raise WatchError("No se pudo crear la vigilancia.")
    meta = _meta(root)
    meta[uuid] = {"kind": kind, "url": url, "label": (label or "").strip()[:120], "below": below,
                  "text": text.strip()[:200], "profile": profile, "created": time.time(), "state": {}}
    _save_meta(root, meta)
    return {"id": uuid, **_summary(root, uuid, meta[uuid])}


def delete(root: Path, uuid: str) -> None:
    meta = _meta(root)
    if uuid not in meta:
        raise WatchError("Esa vigilancia no existe.")
    if running():
        try:
            _api(root, "DELETE", f"/watch/{uuid}")
        except WatchError:
            pass
    meta.pop(uuid, None)
    _save_meta(root, meta)


def _watch_file(root: Path, uuid: str) -> Dict[str, Any]:
    if not re.fullmatch(r"[0-9a-f-]{36}", uuid or ""):
        return {}
    try:
        data = json.loads((_dir(root) / "data" / uuid / "watch.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _summary(root: Path, uuid: str, info: Dict[str, Any]) -> Dict[str, Any]:
    watch = _watch_file(root, uuid)
    restock = watch.get("restock") if isinstance(watch.get("restock"), dict) else {}
    return {
        "kind": info.get("kind"), "url": info.get("url"),
        "label": info.get("label") or watch.get("title") or watch.get("page_title") or info.get("url"),
        "below": info.get("below"), "text": info.get("text") or None,
        "price": restock.get("price"), "currency": restock.get("currency"),
        "in_stock": restock.get("in_stock"),
        "last_checked": watch.get("last_checked") or None, "last_changed": watch.get("last_changed") or None,
        "error": watch.get("last_error") or None,
    }


def listing(root: Path) -> List[Dict[str, Any]]:
    meta = _meta(root)
    rows = [{"id": uuid, **_summary(root, uuid, info)} for uuid, info in meta.items()]
    return sorted(rows, key=lambda row: meta[row["id"]].get("created", 0), reverse=True)


def status(root: Path) -> Dict[str, Any]:
    state = _install_state(root)
    return {"installed": installed(root), "running": running(),
            "installing": state.get("state") == "installing" and _installing.locked(),
            "failed": state.get("error") if state.get("state") == "failed" else None,
            "watches": len(_meta(root))}


# ── What is news ─────────────────────────────────────────────────────────────────


def _latest_text(root: Path, uuid: str) -> Optional[str]:
    try:
        text = _api(root, "GET", f"/watch/{uuid}/history/latest")
    except WatchError:
        return None
    return text if isinstance(text, str) else None


def _money(value: Any, currency: Any) -> str:
    try:
        amount = f"{float(value):.2f}".replace(".", ",")
    except (TypeError, ValueError):
        return str(value)
    return f"{amount} {currency or ''}".strip()


def check(root: Path, now: Optional[float] = None, latest_text=None) -> List[Dict[str, Any]]:
    """Each watch against what it is for; returns only what is new since last time."""
    now = now or time.time()
    latest_text = latest_text or (lambda uuid: _latest_text(root, uuid))
    meta = _meta(root)
    news: List[Dict[str, Any]] = []
    for uuid, info in meta.items():
        watch = _watch_file(root, uuid)
        state = info.setdefault("state", {})
        name = info.get("label") or watch.get("title") or watch.get("page_title") or info.get("url")
        base = {"id": uuid, "label": name, "url": info.get("url")}
        error = watch.get("last_error")
        if error and watch.get("last_checked"):
            since = state.setdefault("error_since", now)
            if now - since > 24 * 3600 and not state.get("error_told"):
                state["error_told"] = True
                news.append({**base, "what": "error", "detail": "No se puede leer la página desde hace un día."})
            continue
        state.pop("error_since", None)
        state.pop("error_told", None)
        if not watch.get("last_checked"):
            continue
        kind = info.get("kind")
        restock = watch.get("restock") if isinstance(watch.get("restock"), dict) else {}
        if kind == "price":
            price = restock.get("price")
            if price is None:
                continue
            price = float(price)
            last = state.get("price")
            below = info.get("below")
            if below is not None:
                under = price <= float(below)
                if under and not state.get("under"):
                    news.append({**base, "what": "price", "price": _money(price, restock.get("currency")),
                                 "detail": f"Está a {_money(price, restock.get('currency'))}, por debajo de "
                                           f"{_money(below, restock.get('currency'))}."})
                state["under"] = under
            elif last is not None and price < float(last):
                news.append({**base, "what": "price", "price": _money(price, restock.get("currency")),
                             "detail": f"Ha bajado de {_money(last, restock.get('currency'))} a "
                                       f"{_money(price, restock.get('currency'))}."})
            state["price"] = price
        elif kind == "stock":
            in_stock = restock.get("in_stock")
            if in_stock is None:
                continue
            if in_stock and state.get("in_stock") is False:
                detail = "Vuelve a estar disponible."
                if restock.get("price") is not None:
                    detail += f" Precio: {_money(restock.get('price'), restock.get('currency'))}."
                news.append({**base, "what": "stock", "detail": detail})
            state["in_stock"] = bool(in_stock)
        elif kind == "change":
            changed = watch.get("last_changed") or 0
            if state.get("changed") is None:
                state["changed"] = changed
            elif changed and changed > state["changed"]:
                state["changed"] = changed
                news.append({**base, "what": "change", "detail": "La página ha cambiado."})
        elif kind == "text":
            wanted = (info.get("text") or "").casefold()
            text = latest_text(uuid)
            if not wanted or text is None:
                continue
            present = wanted in text.casefold()
            if present and not state.get("present"):
                news.append({**base, "what": "text", "detail": f"Ya aparece «{info.get('text')}»."})
            state["present"] = present
    _save_meta(root, meta)
    return news


def facts(news: List[Dict[str, Any]]) -> str:
    """What the routine's script prints: nothing when there is no news."""
    return "\n".join(f"- [{item['label']}]({item['url']}): {item['detail']}" for item in news)


# ── The routine that tells ───────────────────────────────────────────────────────

SCRIPT_BODY = '''#!/usr/bin/env python3
"""Alice: page watches. Prints only news, so the routine wakes the model only for news."""
import importlib.util, os, sys
from pathlib import Path
root = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
if root.parent.name == "profiles":
    root = root.parent.parent
module = root / "plugins" / "alice" / "page_watch.py"
spec = importlib.util.spec_from_file_location("alice_page_watch_script", module)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)
if watch.installed(root) and watch._meta(root):
    watch.start(root)
    text = watch.facts(watch.check(root))
    if text:
        print(text)
'''


def install_routine(root: Path, run=subprocess.run, hermes: str = "hermes") -> str:
    """The script, and the routine that runs it every 10 minutes, once."""
    scripts = Path(root) / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / SCRIPT).write_text(SCRIPT_BODY, encoding="utf-8")
    try:
        jobs = json.loads((Path(root) / "cron" / "jobs.json").read_text(encoding="utf-8"))
        jobs = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    except (OSError, ValueError):
        jobs = []
    if any(isinstance(job, dict) and job.get("name") == ROUTINE for job in jobs or []):
        return "exists"
    made = run([hermes, "cron", "create", "*/10 * * * *", ROUTINE_PROMPT, "--name", ROUTINE,
                "--deliver", "bot-chat", "--script", SCRIPT], capture_output=True, text=True, timeout=120)
    if made.returncode != 0:
        raise WatchError("No se pudo crear la rutina que avisa de las vigilancias.")
    return "created"


def setup(root: Path, **kwargs: Any) -> Dict[str, Any]:
    """Installed, running, the example watches gone, and the routine in place."""
    if not installed(root):
        install(root, **{k: v for k, v in kwargs.items() if k == "python"})
    if not installed(root):
        raise WatchError("No se pudo instalar la vigilancia de páginas.")
    if not start(root):
        raise WatchError("La vigilancia de páginas no arrancó.")
    marker = _dir(root) / "examples-removed"
    if not marker.exists():
        mine = set(_meta(root))
        watches = _api(root, "GET", "/watch") or {}
        for uuid in watches if isinstance(watches, dict) else []:
            if uuid not in mine:
                _api(root, "DELETE", f"/watch/{uuid}")
        marker.write_text("1", encoding="utf-8")
    install_routine(root, **{k: v for k, v in kwargs.items() if k in ("run", "hermes")})
    return status(root)
