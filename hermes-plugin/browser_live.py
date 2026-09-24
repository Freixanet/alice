"""The agents' shared browser, seen and driven from the iPhone.

Hermes can drive any Chromium that has a DevTools (CDP) port: ``browser.cdp_url`` in a
profile's config makes its browser tools use that browser instead of a private one (the
same thing ``/browser connect`` does for a session). Alice turns that on for every profile
with one switch, and keeps a Chromium running for it in the background — headless, so
nothing opens on the Mac, with its own profile in ``<hermes home>/chrome-debug`` so what
someone signs into there stays there for the agents.

The iPhone then watches that browser through the Chrome screencast (JPEG frames pushed by
the browser as the page changes) and sends taps, scrolls and typing back as CDP input. The
CDP port only ever listens on loopback; the phone reaches it through the dashboard, which
needs its login. Nothing typed is logged.
"""
from __future__ import annotations

import base64
import json
import os
import platform
import subprocess
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit

PORT = 9222
MANAGED_URL = f"http://127.0.0.1:{PORT}"
STATE = Path(".alice") / "browser.json"
# Who drives the shared browser: the agents, or the person who took over for a login, a
# 2FA code, a CAPTCHA or a payment. While the person holds it, agents' browser tools wait.
LEASE = Path(".alice") / "browser-lease.json"
# A takeover nobody touches for this long goes back to the agents on its own.
LEASE_IDLE_SECONDS = 15 * 60
# While someone watches, the page draws where the agent acts — the pointer gliding to
# it, a ripple on each click, a glow on the field it types into — so the person sees the
# agent navigate rather than a page changing by itself. Drawn in a layer that takes no
# input and is gone with the document; injected only on the tab being watched.
POINTER_JS = r"""
(() => {
  if (window.__aliceWatch) return; window.__aliceWatch = true;
  const make = () => {
    if (!document.body) return null;
    let p = document.getElementById('__alice_pointer');
    if (p) return p;
    p = document.createElement('div'); p.id = '__alice_pointer';
    p.style.cssText = 'position:fixed;left:0;top:0;width:18px;height:18px;margin:-9px 0 0 -9px;border-radius:50%;'
      + 'background:rgba(255,59,48,.9);box-shadow:0 0 0 3px rgba(255,255,255,.9),0 2px 8px rgba(0,0,0,.35);'
      + 'z-index:2147483647;pointer-events:none;transition:transform .35s cubic-bezier(.2,.8,.2,1),opacity .4s;'
      + 'opacity:0;transform:translate(-40px,-40px)';
    document.documentElement.appendChild(p);
    return p;
  };
  const at = (x, y) => { const p = make(); if (!p) return; p.style.opacity = '1'; p.style.transform = `translate(${x}px,${y}px)`; };
  const ripple = (x, y) => {
    const r = document.createElement('div');
    r.style.cssText = `position:fixed;left:${x}px;top:${y}px;width:12px;height:12px;margin:-6px 0 0 -6px;border-radius:50%;`
      + 'border:3px solid rgba(255,59,48,.85);z-index:2147483647;pointer-events:none;'
      + 'transition:transform .6s ease-out,opacity .6s ease-out;transform:scale(1);opacity:1';
    document.documentElement.appendChild(r);
    requestAnimationFrame(() => { r.style.transform = 'scale(5)'; r.style.opacity = '0'; });
    setTimeout(() => r.remove(), 700);
  };
  const center = (el) => { const b = el.getBoundingClientRect(); return [b.left + b.width / 2, b.top + b.height / 2]; };
  const glow = (el) => {
    if (!el || !el.style) return;
    const before = el.style.boxShadow;
    el.style.boxShadow = '0 0 0 3px rgba(255,59,48,.75)';
    clearTimeout(el.__aliceGlow); el.__aliceGlow = setTimeout(() => { el.style.boxShadow = before; }, 900);
  };
  addEventListener('mousemove', e => at(e.clientX, e.clientY), true);
  addEventListener('mousedown', e => { at(e.clientX, e.clientY); ripple(e.clientX, e.clientY); }, true);
  addEventListener('click', e => {
    // A script click has no coordinates: show it on the element instead.
    if (e.clientX || e.clientY) return;
    const [x, y] = center(e.target); at(x, y); ripple(x, y);
  }, true);
  addEventListener('focusin', e => { const [x, y] = center(e.target); at(x, y); glow(e.target); }, true);
  addEventListener('input', e => glow(e.target), true);
})();
"""

# With no new screencast frame for this long, a screenshot is taken instead.
STALE_SECONDS = 1.5
# Frames stop being produced once no phone has asked for one for this long.
IDLE_SECONDS = 20
# Tablet-portrait: sites lay out for it, and it reads on a phone without much zoom.
WINDOW = "820,1300"
KEYS = {
    "Enter": (13, "\r"), "Backspace": (8, ""), "Tab": (9, ""), "Escape": (27, ""),
    "ArrowDown": (40, ""), "ArrowUp": (38, ""),
}


class BrowserError(Exception):
    pass


# ── Where the browser is ─────────────────────────────────────────────────────────


def _profile_homes(root: Path) -> List[Path]:
    homes = [Path(root)]
    profiles = Path(root) / "profiles"
    if profiles.is_dir():
        homes += sorted(p for p in profiles.iterdir() if (p / "config.yaml").is_file())
    return homes


def _read_yaml(path: Path) -> Dict[str, Any]:
    try:
        import yaml

        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def configured_url(root: Path) -> str:
    """The CDP address Alice's own profile uses, if one is set."""
    browser = _read_yaml(Path(root) / "config.yaml").get("browser")
    return str((browser or {}).get("cdp_url") or "").strip() if isinstance(browser, dict) else ""


def _http_root(url: str) -> str:
    parts = urlsplit(url if "://" in url else f"http://{url}")
    scheme = {"ws": "http", "wss": "https"}.get(parts.scheme, parts.scheme or "http")
    return f"{scheme}://{parts.netloc}"


def _local(url: str) -> bool:
    host = (urlsplit(url if "://" in url else f"http://{url}").hostname or "").lower()
    return host in ("127.0.0.1", "localhost", "::1")


def _get_json(url: str, timeout: float = 1.5) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:  # noqa: S310 — loopback only
        return json.loads(response.read().decode("utf-8"))


def reachable(url: str) -> bool:
    if not url or not _local(url):
        return False
    try:
        return isinstance(_get_json(_http_root(url) + "/json/version", 1.0), dict)
    except Exception:
        return False


def pages(url: str) -> List[Dict[str, str]]:
    """Open tabs, most recently used first, without Chrome's own pages."""
    try:
        rows = _get_json(_http_root(url) + "/json/list")
    except Exception:
        return []
    found = []
    for row in rows if isinstance(rows, list) else []:
        address = str(row.get("url") or "")
        if row.get("type") != "page" or address.startswith(("devtools://", "chrome-extension://", "chrome://")):
            continue
        if not row.get("webSocketDebuggerUrl"):
            continue
        found.append({"id": row.get("id", ""), "title": row.get("title") or "", "url": address,
                      "ws": row["webSocketDebuggerUrl"]})
    return found


# ── Keeping it running ───────────────────────────────────────────────────────────


def _binary() -> Optional[str]:
    try:
        from hermes_cli.browser_connect import get_chrome_debug_candidates

        candidates = get_chrome_debug_candidates(platform.system())
    except Exception:
        candidates = []
    return candidates[0] if candidates else None


def launch(root: Path, *, binary: Optional[str] = None, port: int = PORT, wait: float = 15.0) -> bool:
    """A headless Chromium on the Hermes debug profile, unless one already answers."""
    url = f"http://127.0.0.1:{port}"
    if reachable(url):
        return True
    binary = binary or _binary()
    if not binary:
        raise BrowserError("No hay Chrome, Chromium, Edge ni Brave instalado en este ordenador.")
    data = Path(root) / "chrome-debug"
    data.mkdir(parents=True, exist_ok=True)
    log = open(data / "alice-headless.log", "ab")  # noqa: SIM115 — handed to the child
    subprocess.Popen(  # noqa: S603 — a fixed browser binary and fixed flags
        [binary, "--headless=new", f"--remote-debugging-port={port}", "--remote-debugging-address=127.0.0.1",
         f"--user-data-dir={data}", "--no-first-run", "--no-default-browser-check",
         f"--window-size={WINDOW}", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=log, start_new_session=True)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if reachable(url):
            return True
        time.sleep(0.4)
    return False


def _state(root: Path) -> Dict[str, Any]:
    try:
        data = json.loads((Path(root) / STATE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_state(root: Path, state: Dict[str, Any]) -> None:
    path = Path(root) / STATE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=1), encoding="utf-8")


# ── Who is in control ────────────────────────────────────────────────────────────


def _read_lease(root: Path) -> Dict[str, Any]:
    try:
        data = json.loads((Path(root) / LEASE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_lease(root: Path, data: Dict[str, Any]) -> None:
    path = Path(root) / LEASE
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(data), encoding="utf-8")
    os.replace(temp, path)


def control(root: Path, now: Optional[float] = None) -> Dict[str, Any]:
    """``{"holder": "human" | "agent", "since": …}``; a forgotten takeover lapses."""
    now = time.time() if now is None else now
    lease = _read_lease(root)
    if lease.get("holder") == "human":
        if now - float(lease.get("touched") or lease.get("since") or 0) < LEASE_IDLE_SECONDS:
            return {"holder": "human", "since": lease.get("since")}
        _write_lease(root, {"holder": "agent", "since": now, "lapsed": True})
        return {"holder": "agent", "since": now}
    return {"holder": "agent", "since": lease.get("since")}


def take_over(root: Path, now: Optional[float] = None) -> Dict[str, Any]:
    now = time.time() if now is None else now
    current = _read_lease(root)
    since = current.get("since") if current.get("holder") == "human" else now
    _write_lease(root, {"holder": "human", "since": since, "touched": now})
    return control(root, now)


def hand_back(root: Path, now: Optional[float] = None) -> Dict[str, Any]:
    now = time.time() if now is None else now
    _write_lease(root, {"holder": "agent", "since": now})
    return control(root, now)


def touched(root: Path, now: Optional[float] = None) -> None:
    """The person used the page: their takeover stays fresh."""
    lease = _read_lease(root)
    if lease.get("holder") == "human":
        lease["touched"] = time.time() if now is None else now
        _write_lease(root, lease)


def managed(root: Path) -> bool:
    return bool(_state(root).get("managed"))


def ensure(root: Path) -> bool:
    """Before an agent browses: the shared browser is up if Alice manages it."""
    if not managed(root) or configured_url(root) != MANAGED_URL:
        return True
    return launch(root)


def enable(root: Path, set_cdp, *, binary: Optional[str] = None) -> Dict[str, Any]:
    """Every profile browses in the shared browser, started now.

    ``set_cdp(home, value)`` writes ``browser.cdp_url`` for the profile at ``home`` (None
    clears it) through Hermes' own config writer, and returns what was there before.
    """
    if not launch(root, binary=binary):
        raise BrowserError("El navegador no arrancó. Prueba otra vez en un momento.")
    state = _state(root)
    previous = state.get("previous") if isinstance(state.get("previous"), dict) else {}
    for home in _profile_homes(root):
        name = "default" if home == Path(root) else home.name
        before = set_cdp(home, MANAGED_URL)
        if name not in previous and before != MANAGED_URL:
            previous[name] = before
    _save_state(root, {"managed": True, "previous": previous, "since": time.time()})
    return status(root)


def disable(root: Path, set_cdp) -> Dict[str, Any]:
    """Back to each profile's own browser; the shared one is closed."""
    state = _state(root)
    previous = state.get("previous") if isinstance(state.get("previous"), dict) else {}
    for home in _profile_homes(root):
        name = "default" if home == Path(root) else home.name
        config = _read_yaml(home / "config.yaml")
        current = str(((config.get("browser") or {}) if isinstance(config.get("browser"), dict) else {})
                      .get("cdp_url") or "")
        if current == MANAGED_URL:
            set_cdp(home, previous.get(name))
    _save_state(root, {"managed": False})
    stop_all()
    try:
        info = _get_json(MANAGED_URL + "/json/version", 1.0)
        _command(info["webSocketDebuggerUrl"], "Browser.close", {})
    except Exception:
        pass
    return status(root)


def status(root: Path) -> Dict[str, Any]:
    url = configured_url(root)
    up = reachable(url) if url else False
    tabs = pages(url) if up else []
    return {"managed": managed(root), "configured": bool(url), "local": _local(url) if url else False,
            "control": control(root)["holder"],
            "running": up, "available": _binary() is not None or up,
            "page": {"title": tabs[0]["title"], "url": tabs[0]["url"]} if tabs else None,
            "tabs": len(tabs)}


def _command(ws_url: str, method: str, params: Dict[str, Any]) -> None:
    from websockets.sync.client import connect

    with connect(ws_url, open_timeout=3, max_size=None) as socket:
        socket.send(json.dumps({"id": 1, "method": method, "params": params}))
        socket.recv(timeout=3)


# ── Watching and driving ─────────────────────────────────────────────────────────


class Screencast:
    """One tab's screencast: the latest frame, and a line to send input on."""

    def __init__(self, page: Dict[str, str]):
        self.page = page
        self.seq = 0
        self.frame: Optional[bytes] = None
        self.meta: Dict[str, Any] = {}
        self.touched = time.monotonic()
        self.closed = False
        self.error: Optional[str] = None
        self.titled = 0.0
        self._ids = 10
        self._changed = threading.Condition()
        self._socket = None
        # Set once the tab's socket is open: an action that arrives first waits for it.
        self._connected = threading.Event()
        self._send_lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, name="alice-screencast", daemon=True)
        self._thread.start()

    def _send(self, method: str, params: Dict[str, Any]) -> None:
        with self._send_lock:
            if self._socket is None:
                raise BrowserError("El navegador no está conectado.")
            self._ids += 1
            self._socket.send(json.dumps({"id": self._ids, "method": method, "params": params}))

    def _run(self) -> None:
        from websockets.sync.client import connect

        try:
            with connect(self.page["ws"], open_timeout=5, max_size=None) as socket:
                self._socket = socket
                self._connected.set()
                self._send("Page.enable", {})
                # Where the agent acts, drawn on the page while it is watched.
                self._send("Page.addScriptToEvaluateOnNewDocument", {"source": POINTER_JS})
                self._send("Runtime.evaluate", {"expression": POINTER_JS})
                self._send("Page.startScreencast", {"format": "jpeg", "quality": 62,
                                                    "maxWidth": 1200, "maxHeight": 1800, "everyNthFrame": 1})
                self._send("Page.captureScreenshot", {"format": "jpeg", "quality": 62})
                asked = time.monotonic()
                while not self.closed:
                    now = time.monotonic()
                    if now - self.touched > IDLE_SECONDS:
                        break
                    # The screencast goes quiet after some navigations and on pages
                    # that stop repainting: a picture every second and a half anyway.
                    if now - max(getattr(self, "framed", 0.0), asked) > STALE_SECONDS:
                        asked = now
                        self._send("Page.captureScreenshot", {"format": "jpeg", "quality": 62})
                    try:
                        raw = socket.recv(timeout=0.5)
                    except TimeoutError:
                        continue
                    message = json.loads(raw)
                    method = message.get("method")
                    if method == "Page.screencastFrame":
                        params = message.get("params") or {}
                        self._store(params.get("data"), params.get("metadata") or {})
                        self._send("Page.screencastFrameAck", {"sessionId": params.get("sessionId")})
                    elif method == "Page.frameNavigated":
                        frame = (message.get("params") or {}).get("frame") or {}
                        if not frame.get("parentId"):
                            self.page["url"] = frame.get("url") or self.page["url"]
                            # A new document ends the old screencast: start it again.
                            self._send("Page.startScreencast", {"format": "jpeg", "quality": 62, "maxWidth": 1200,
                                                                "maxHeight": 1800, "everyNthFrame": 1})
                    elif method == "Inspector.detached" or method == "Target.targetDestroyed":
                        break
                    elif isinstance(message.get("result"), dict) and message["result"].get("data"):
                        self._store(message["result"]["data"], {})
                try:
                    self._send("Page.stopScreencast", {})
                except Exception:
                    pass
        except Exception as exc:  # noqa: BLE001 — reported to the phone, never raised in a thread
            self.error = "No se pudo conectar con el navegador."
            _ = exc
        finally:
            self._socket = None
            self.closed = True
            with self._changed:
                self._changed.notify_all()

    def _store(self, data: Optional[str], meta: Dict[str, Any]) -> None:
        if not data:
            return
        self.framed = time.monotonic()
        with self._changed:
            self.frame = base64.b64decode(data)
            if meta:
                self.meta = meta
            self.seq += 1
            self._changed.notify_all()

    def wait(self, after: int, timeout: float) -> bool:
        self.touched = time.monotonic()
        with self._changed:
            return self._changed.wait_for(lambda: self.seq > after or self.closed, timeout=timeout)

    def act(self, action: Dict[str, Any]) -> None:
        self.touched = time.monotonic()
        # The first touch after a quiet spell reopens the tab's socket; give it time.
        connected = getattr(self, "_connected", None)
        if connected is not None:
            connected.wait(timeout=5)
        kind = str(action.get("kind") or "")
        width = float(self.meta.get("deviceWidth") or 1000)
        height = float(self.meta.get("deviceHeight") or 1400)
        x = max(0.0, min(1.0, float(action.get("x") or 0))) * width
        y = max(0.0, min(1.0, float(action.get("y") or 0))) * height
        if kind == "tap":
            self._send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})
            self._send("Input.dispatchMouseEvent",
                       {"type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1})
            self._send("Input.dispatchMouseEvent",
                       {"type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1})
        elif kind == "scroll":
            delta = max(-1.0, min(1.0, float(action.get("dy") or 0))) * height
            self._send("Input.dispatchMouseEvent",
                       {"type": "mouseWheel", "x": x, "y": y, "deltaX": 0, "deltaY": delta})
        elif kind == "text":
            text = str(action.get("text") or "")[:2000]
            if text:
                self._send("Input.insertText", {"text": text})
        elif kind == "key":
            key = str(action.get("key") or "")
            if key not in KEYS:
                raise BrowserError("Esa tecla no se puede enviar.")
            code, text = KEYS[key]
            for phase in ("keyDown", "keyUp"):
                event = {"type": phase, "key": key, "code": key, "windowsVirtualKeyCode": code,
                         "nativeVirtualKeyCode": code}
                if phase == "keyDown" and text:
                    event["text"] = text
                self._send("Input.dispatchKeyEvent", event)
        elif kind == "navigate":
            address = str(action.get("url") or "").strip()
            scheme = address.split(":", 1)[0].lower() if ":" in address.split("/", 1)[0] else ""
            if scheme and scheme not in ("http", "https") and not scheme.isdigit():
                raise BrowserError("Solo se abren direcciones web.")
            if not address.startswith(("http://", "https://")):
                address = "https://" + address
            if urlsplit(address).scheme not in ("http", "https") or not urlsplit(address).hostname:
                raise BrowserError("Solo se abren direcciones web.")
            self._send("Page.navigate", {"url": address})
        elif kind in ("back", "forward"):
            self._send("Runtime.evaluate", {"expression": f"history.{kind}()"})
        elif kind == "reload":
            self._send("Page.reload", {})
        else:
            raise BrowserError("Esa acción no existe.")


_casts: Dict[str, Screencast] = {}
_casts_lock = threading.Lock()
# What each tab last showed and when it changed. An agent browses in a tab of its own
# (Hermes pins each browser session to one), so "the page to watch" is the tab where
# something last happened — opened, navigated or retitled — not the first in Chrome's list.
_seen: Dict[str, Any] = {}
_changed: Dict[str, float] = {}


def busiest(tabs: List[Dict[str, str]], now: Optional[float] = None) -> Optional[Dict[str, str]]:
    """The tab that changed most recently; a new tab counts as a change."""
    now = time.monotonic() if now is None else now
    first_look = not _seen
    ids = set()
    for tab in tabs:
        ids.add(tab["id"])
        shown = (tab.get("url"), tab.get("title"))
        if _seen.get(tab["id"]) != shown:
            _seen[tab["id"]] = shown
            # A tab seen for the first time on the very first look is not news.
            _changed[tab["id"]] = 0.0 if first_look and len(tabs) > 1 else now
    for gone in [key for key in _seen if key not in ids]:
        _seen.pop(gone, None)
        _changed.pop(gone, None)
    if not tabs:
        return None
    # A blank tab shows nothing: an agent's fresh tab is about:blank for a moment.
    real = [tab for tab in tabs if str(tab.get("url") or "").startswith(("http://", "https://"))] or tabs
    return max(real, key=lambda tab: (_changed.get(tab["id"], 0.0), -real.index(tab)))


def _cast(root: Path, target: Optional[str] = None) -> Screencast:
    url = configured_url(root)
    if not url:
        raise BrowserError("El navegador compartido no está activado.")
    if not _local(url):
        raise BrowserError("El navegador de los agentes está en otro ordenador; desde aquí no se puede ver.")
    if not reachable(url):
        if managed(root) and url == MANAGED_URL:
            launch(root)
        if not reachable(url):
            raise BrowserError("El navegador de los agentes no está abierto.")
    tabs = pages(url)
    if not tabs:
        raise BrowserError("No hay ninguna página abierta.")
    chosen = next((t for t in tabs if t["id"] == target), None) if target else None
    # Unless the phone asked for a tab, follow the one where the agent is working.
    page = chosen or busiest(tabs) or tabs[0]
    with _casts_lock:
        # One live cast at a time: the tab the phone is looking at.
        for key, cast in list(_casts.items()):
            if key != page["id"] or cast.closed:
                cast.closed = True
                _casts.pop(key, None)
        cast = _casts.get(page["id"])
        if cast is None:
            cast = Screencast(dict(page))
            _casts[page["id"]] = cast
        return cast


def frame(root: Path, after: int = 0, wait: float = 1.5, target: Optional[str] = None) -> Dict[str, Any]:
    cast = _cast(root, target)
    cast.wait(after, wait)
    if cast.error:
        raise BrowserError(cast.error)
    # The title is not in the screencast; the tab list has it, read at most every 2 s.
    if time.monotonic() - cast.titled > 2:
        cast.titled = time.monotonic()
        for tab in pages(configured_url(root)):
            if tab["id"] == cast.page.get("id"):
                cast.page["title"], cast.page["url"] = tab["title"], tab["url"]
    return {"seq": cast.seq, "jpeg": cast.frame, "width": cast.meta.get("deviceWidth"),
            "height": cast.meta.get("deviceHeight"), "title": cast.page.get("title") or "",
            "url": cast.page.get("url") or "", "target": cast.page.get("id") or ""}


def act(root: Path, action: Dict[str, Any], target: Optional[str] = None) -> None:
    _cast(root, target).act(action)
    touched(root)


def stop_all() -> None:
    with _casts_lock:
        for cast in _casts.values():
            cast.closed = True
        _casts.clear()
