"""Alice for Hermes — dashboard backend, mounted at ``/api/plugins/alice/``.

Two things Alice needs from a Hermes that Hermes itself does not ship:

* **QR pairing** (Alice ``docs/pairing.md``). ``POST pairing/session`` — behind the
  dashboard's own login — mints a short-lived ``alice://pair`` link for the installation's
  main profile, provisioning that profile's gateway when it has none. ``POST pairing/claim``
  exchanges the one-time code for the gateway and dashboard credentials. The phone has no
  dashboard login yet, so the claim is authenticated by Hermes' token-auth seam: this module
  registers a token provider that recognises outstanding pairing codes and opts the claim
  route (only) into that seam. Hermes' public path list is left untouched.
* **Curated memory** (MEMORY.md / USER.md) per profile: ``GET memory`` and ``POST memory``.
* **Notes**: ``GET notes`` and ``POST notes`` read and add to the notes store an agent keeps
  in its workspace (``workspace/inbox-store``, the Inbox agent's). Writes go through the
  store's own ``inbox.py add``, so its append-only contract is the store's, not ours.

It lives outside Hermes' checkout, so ``hermes update`` never collides with it.
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import fcntl
import http.client
import ipaddress
import json
import logging
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
from collections import defaultdict, deque
from pathlib import Path
from typing import Any, Deque, Dict, List, Optional, Tuple

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

_log = logging.getLogger("hermes_dashboard_plugin_alice")
router = APIRouter()

PLUGIN_PREFIX = "/api/plugins/alice"
CLAIM_PATH = f"{PLUGIN_PREFIX}/pairing/claim"

OFFER_TTL_SECONDS = 300
MAX_PENDING_OFFERS = 256
MAX_PENDING_PER_IP = 8
CLAIM_BODY_MAX_BYTES = 4096
CLAIM_RATE_MAX_PER_WINDOW = 30
CLAIM_RATE_WINDOW_SEC = 60.0
# Ports for a freshly provisioned main-profile gateway; 8642 is left to bot gateways.
MAIN_GATEWAY_PORT_CANDIDATES = range(8643, 8670)

_lock = threading.Lock()
# token -> {expires_at, config?, used, ip, profile, created_at}
_offers: Dict[str, Dict[str, Any]] = {}
_claim_attempts: Dict[str, Deque[float]] = defaultdict(deque)
_claim_attempts_lock = threading.Lock()

_NO_STORE = {"Cache-Control": "no-store, max-age=0", "Pragma": "no-cache"}


# --- Claim authentication through Hermes' token-auth seam ---------------------------------

def _provider_class():
    from hermes_cli.dashboard_auth import DashboardAuthProvider, TokenPrincipal

    class PairingCodeProvider(DashboardAuthProvider):
        """Recognises outstanding Alice pairing codes as bearer tokens.

        A code already claimed stays recognised until it expires, so the claim route can
        answer 410 ("already used") rather than a bare 401. Holding a live code is worth no
        more than claiming it, which hands over the gateway key and dashboard login.
        """

        name = "alice-pairing"
        display_name = "Alice pairing code"
        supports_token = True
        supports_session = False
        _NOT_INTERACTIVE = "Alice pairing codes are one-time bearer tokens; there is no login."

        def start_login(self, *, redirect_uri: str):
            raise NotImplementedError(self._NOT_INTERACTIVE)

        def complete_login(self, *, code: str, state: str, code_verifier: str, redirect_uri: str):
            raise NotImplementedError(self._NOT_INTERACTIVE)

        def verify_session(self, *, access_token: str):
            return None

        def refresh_session(self, *, refresh_token: str):
            raise NotImplementedError(self._NOT_INTERACTIVE)

        def revoke_session(self, *, refresh_token: str) -> None:
            return None

        def verify_token(self, *, token: str):
            if not token:
                return None
            with _lock:
                _gc_offers_locked(time.time())
                known = token in _offers
            if not known:
                return None
            return TokenPrincipal(principal="alice-pairing", provider=self.name, scopes=("alice-pairing-claim",))

    return PairingCodeProvider


def _register_claim_auth() -> None:
    try:
        from hermes_cli.dashboard_auth.registry import register_global_provider
        from hermes_cli.dashboard_auth.token_auth import register_token_route

        register_global_provider(_provider_class()())
        register_token_route(CLAIM_PATH)
    except Exception as exc:  # noqa: BLE001 — a Hermes without the seam keeps the rest working
        _log.warning("alice: pairing claims are unavailable (token auth seam missing: %s)", exc)


# --- Protocol: exact Alice v1 envelope -----------------------------------------------------

def _b64url(data: bytes) -> str:
    """RFC 4648 §5 without padding, matching Alice's strict parser."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _canonical_offer_bytes(offer: Dict[str, Any]) -> bytes:
    payload: Dict[str, Any] = {"c": offer["c"], "t": offer["t"], "e": offer["e"]}
    if offer.get("pr"):
        payload["pr"] = offer["pr"]
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def _build_pairing_link(offer: Dict[str, Any]) -> str:
    return f"alice://pair?v=1&p={_b64url(_canonical_offer_bytes(offer))}"


# --- Hermes helpers, imported late so an old or new Hermes can still load this file ---------

def _load_config() -> Dict[str, Any]:
    from hermes_cli.config import load_config

    return load_config() or {}


def _cfg_get(config: Dict[str, Any], *keys: str, default: Any = None) -> Any:
    value: Any = config
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return default
        value = value[key]
    return value


def _list_profiles():
    from hermes_cli.profiles import list_profiles

    return list_profiles() or []


@contextlib.contextmanager
def _profile_scope(profile: str):
    """Point Hermes' home-derived helpers (.env, launchd, memory) at one profile."""
    from hermes_cli.profiles import get_profile_dir
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override

    token = set_hermes_home_override(get_profile_dir(profile))
    try:
        yield
    finally:
        reset_hermes_home_override(token)


def _read_profile_env(profile: str) -> Dict[str, str]:
    from hermes_constants import get_default_hermes_root

    root = Path(get_default_hermes_root())
    env_path = root / ".env" if profile == "default" else root / "profiles" / profile / ".env"
    values: Dict[str, str] = {}
    try:
        lines = env_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        equals = line.find("=")
        if equals <= 0:
            continue
        key = line[:equals].strip()
        if key:
            values[key] = line[equals + 1:].strip().strip("'\"")
    return values


def _tailscale_status() -> Dict[str, Any]:
    try:
        proc = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(proc.stdout) or {}
    except ValueError:
        return {}


def _tailscale_dns_name() -> Optional[str]:
    name = (_tailscale_status().get("Self", {}) or {}).get("DNSName") or ""
    return name.rstrip(".").strip() or None


def _tailscale_ipv4() -> Optional[str]:
    ips = (_tailscale_status().get("Self", {}) or {}).get("TailscaleIPs") or []
    return next((ip for ip in ips if _is_ipv4(ip)), None)


def _resolve_main_profile() -> Tuple[str, str]:
    """The installation's main profile (``is_default``) — who Alice's Home chat talks to."""
    main = next((p for p in _list_profiles() if getattr(p, "is_default", False)), None)
    if main is None:
        raise HTTPException(status_code=503, detail="No default Hermes profile was found on this installation.")
    return main.name, (getattr(main, "display_name", "") or "").strip()


def _main_gateway_running(profile: str) -> bool:
    return any(
        getattr(p, "name", None) == profile and getattr(p, "gateway_running", False) for p in _list_profiles()
    )


def _port_bindable(address: str, port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind((address, port))
        return True
    except OSError:
        return False


def _allocate_gateway_port() -> int:
    for port in MAIN_GATEWAY_PORT_CANDIDATES:
        if _port_bindable("127.0.0.1", port):
            return port
    raise HTTPException(status_code=503, detail="No free local port was available for the main Hermes gateway.")


def _valid_port(raw: Any) -> Optional[int]:
    try:
        port = int(raw)
    except (TypeError, ValueError):
        return None
    return port if 1 <= port <= 65535 else None


def _configured_gateway_is_live(env: Dict[str, str]) -> bool:
    """A port that cannot be bound may be the main gateway itself: check with its key first."""
    key = (env.get("API_SERVER_KEY") or "").strip()
    port = _valid_port(env.get("API_SERVER_PORT"))
    host = (env.get("API_SERVER_HOST") or "").strip().strip("[]").lower()
    if not key or port is None or host not in {"127.0.0.1", "localhost", "0.0.0.0", "::"}:
        return False
    if _port_bindable("127.0.0.1", port):
        return False
    try:
        _probe_gateway("127.0.0.1", port, key)
    except HTTPException:
        return False
    return True


def _provision_main_gateway_env(env: Dict[str, str], *, gateway_running: bool = False) -> Dict[str, str]:
    """Create missing gateway settings in the main profile's .env. A live gateway is never rewritten."""
    if gateway_running:
        return {}
    from hermes_cli.config import save_env_value

    writes: Dict[str, str] = {}
    if not (env.get("API_SERVER_KEY") or "").strip():
        writes["API_SERVER_KEY"] = secrets.token_urlsafe(48)
    host = (env.get("API_SERVER_HOST") or "").strip().strip("[]").lower()
    if host not in {"127.0.0.1", "localhost", "0.0.0.0", "::"}:
        # Exposure is Tailscale Serve's job, not a routable bind.
        writes["API_SERVER_HOST"] = "127.0.0.1"
        host = "127.0.0.1"
    port = _valid_port(env.get("API_SERVER_PORT"))
    if port is None or not _port_bindable(host, port):
        writes["API_SERVER_PORT"] = str(_allocate_gateway_port())
    for key, value in writes.items():
        save_env_value(key, value)
        _log.info("alice pairing: provisioned %s for the main gateway", key)  # the name, never the value
    return writes


def _set_dashboard_key(key: str, value: Any) -> None:
    from hermes_cli.config import load_config, save_config

    # The lock every dashboard config write takes; it moved modules in September 2026.
    try:
        from hermes_cli.web_routers._common import _CONFIG_MUTATION_LOCK as lock
    except Exception:  # noqa: BLE001
        try:
            from hermes_cli.web_server import _CONFIG_MUTATION_LOCK as lock
        except Exception:  # noqa: BLE001
            lock = contextlib.nullcontext()
    with lock:
        config = load_config() or {}
        dashboard = config.get("dashboard")
        if not isinstance(dashboard, dict):
            dashboard = {}
            config["dashboard"] = dashboard
        dashboard[key] = value
        save_config(config)


def _start_main_gateway(profile: str) -> None:
    """Start only the main profile's gateway through Hermes' own service lifecycle."""
    if sys.platform != "darwin":
        raise HTTPException(
            status_code=503,
            detail=f"Start the Hermes gateway for profile '{profile}' (hermes gateway start) and try again.",
        )
    from hermes_cli.gateway import launchd_start

    try:
        launchd_start()
    except SystemExit as exc:
        raise HTTPException(status_code=503, detail=f"Could not start the main Hermes gateway for '{profile}'.") from exc


def _await_gateway_socket(address: str, port: int, timeout: float = 90.0) -> None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            with socket.create_connection((address, port), timeout=2.0):
                return
        except OSError:
            if time.monotonic() >= deadline:
                raise HTTPException(
                    status_code=503, detail="The main Hermes gateway did not become reachable after being started."
                ) from None
            time.sleep(1.0)


def _tailscale_tcp_forward_target(port: int) -> Optional[str]:
    try:
        result = subprocess.run(["tailscale", "serve", "status", "--json"], check=False,
                                capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return None
    rule = (payload.get("TCP") or {}).get(str(port)) if isinstance(payload.get("TCP"), dict) else None
    target = rule.get("TCPForward") if isinstance(rule, dict) else None
    return target.strip() if isinstance(target, str) and target.strip() else None


def _forwards_to_loopback(port: int) -> bool:
    target = _tailscale_tcp_forward_target(port)
    return bool(target) and target.lower().removeprefix("tcp://") in {f"127.0.0.1:{port}", f"localhost:{port}"}


def _ensure_tailscale_forward(port: int) -> None:
    """Publish a localhost-bound port inside the tailnet; other forwards and funnel stay untouched."""
    if _forwards_to_loopback(port):
        return
    result = subprocess.run(
        ["tailscale", "serve", "--bg", "--yes", "--tcp", str(port), f"tcp://127.0.0.1:{port}"],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise HTTPException(
            status_code=503,
            detail=f"Tailscale Serve could not publish port {port} inside the tailnet{': ' + detail if detail else '.'}",
        )


def _is_ipv4(value: str) -> bool:
    try:
        return isinstance(ipaddress.ip_address(value), ipaddress.IPv4Address)
    except ValueError:
        return False


_HOST_LABEL = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


def _validated_advertised_host(raw: Any) -> Optional[str]:
    value = str(raw or "").strip().rstrip(".")
    if not value or len(value) > 253 or any(ch.isspace() for ch in value) or any(ch in value for ch in "/:@"):
        return None
    if _is_ipv4(value):
        address = ipaddress.ip_address(value)
        return None if address.is_loopback or address.is_unspecified else value
    if value.lower() == "localhost" or all(ch.isdigit() or ch == "." for ch in value):
        return None
    if any(not label or not _HOST_LABEL.fullmatch(label) for label in value.split(".")):
        return None
    return value


def _source_ip(request: Request) -> str:
    """The actual peer, never a client-controlled forwarded header."""
    return request.client.host if request.client else ""


def _origin_allowed(ip: str) -> bool:
    """Claims are accepted only from loopback or Tailscale IPv4 (100.64.0.0/10)."""
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    if address.is_loopback:
        return True
    return isinstance(address, ipaddress.IPv4Address) and address in ipaddress.ip_network("100.64.0.0/10")


def _dashboard_reachable_on(address: str, bound_host: Any, bound_port: int) -> bool:
    bound = str(bound_host or "127.0.0.1").strip().strip("[]").rstrip(".").lower()
    if bound in {"0.0.0.0", "::"} or bound == address.rstrip(".").lower():
        return True
    return bound in {"127.0.0.1", "localhost", ""} and _forwards_to_loopback(bound_port)


def _probe_gateway(address: str, port: int, key: str) -> None:
    """Probe the exact host/port Alice will use, without following redirects."""
    headers = {"Accept": "application/json", "Authorization": f"Bearer {key}", "X-Hermes-Session-Token": key}
    last_error: Optional[Exception] = None
    for route in ("/v1/capabilities", "/v1/models"):
        conn = http.client.HTTPConnection(address, port, timeout=6)
        try:
            conn.request("GET", route, headers=headers)
            response = conn.getresponse()
            response.read(1024)
            if 200 <= response.status < 300:
                return
            if response.status in (401, 403):
                raise HTTPException(status_code=503, detail="The Hermes gateway rejected its configured API key.")
        except HTTPException:
            raise
        except (OSError, http.client.HTTPException) as exc:
            last_error = exc
        finally:
            conn.close()
    raise HTTPException(
        status_code=503, detail="The Hermes gateway is not reachable at the address Alice would use."
    ) from last_error


def _has_forwarding_headers(request: Request) -> bool:
    return any(request.headers.get(name) for name in ("forwarded", "x-forwarded-for", "x-real-ip"))


def _claim_rate_limited(ip: str) -> bool:
    now = time.monotonic()
    with _claim_attempts_lock:
        bucket = _claim_attempts[ip or "_unknown_"]
        while bucket and bucket[0] < now - CLAIM_RATE_WINDOW_SEC:
            bucket.popleft()
        if len(bucket) >= CLAIM_RATE_MAX_PER_WINDOW:
            return True
        bucket.append(now)
        return False


def _reset_claim_state_for_tests() -> None:
    with _lock:
        _offers.clear()
    with _claim_attempts_lock:
        _claim_attempts.clear()


async def _build_pairing_config(request: Request) -> Tuple[Dict[str, Any], str, str, str]:
    """Assemble exactly the configuration Alice will receive, for the main profile."""
    profile, display_name = await asyncio.to_thread(_resolve_main_profile)
    with _profile_scope(profile):
        config, address = await _build_main_profile_config(request, profile)
    if display_name:
        config["profile_display_name"] = display_name
    return config, profile, address, display_name


async def _build_main_profile_config(request: Request, profile: str) -> Tuple[Dict[str, Any], str]:
    env = await asyncio.to_thread(_read_profile_env, profile)
    gateway_running = await asyncio.to_thread(_main_gateway_running, profile)
    if not gateway_running and await asyncio.to_thread(_configured_gateway_is_live, env):
        gateway_running = True
    writes = await asyncio.to_thread(_provision_main_gateway_env, env, gateway_running=gateway_running)
    env = {**env, **writes}

    key = env.get("API_SERVER_KEY")
    if not key:
        raise HTTPException(status_code=503, detail=f"The main profile '{profile}' has no gateway key.")
    gateway_port = _valid_port(env.get("API_SERVER_PORT") or 8642)
    if gateway_port is None:
        raise HTTPException(status_code=503, detail="The Hermes gateway port is invalid.")
    if not gateway_running:
        await asyncio.to_thread(_start_main_gateway, profile)

    configured_address = _cfg_get(_load_config(), "dashboard", "alice_pairing", "address")
    raw_address = (configured_address or await asyncio.to_thread(_tailscale_dns_name)
                   or await asyncio.to_thread(_tailscale_ipv4))
    address = _validated_advertised_host(raw_address)
    if not address:
        raise HTTPException(
            status_code=503,
            detail=("Could not determine a safe address to advertise. Install Tailscale, or set "
                    "dashboard.alice_pairing.address to a hostname reachable through the tailnet."),
        )

    bound_port = _valid_port(getattr(request.app.state, "bound_port", 9119))
    if bound_port is None:
        raise HTTPException(status_code=503, detail="The dashboard port is invalid.")
    bound_host = getattr(request.app.state, "bound_host", "127.0.0.1")
    if str(bound_host or "").strip().strip("[]").lower() in {"127.0.0.1", "localhost", ""}:
        await asyncio.to_thread(_ensure_tailscale_forward, bound_port)
    if not await asyncio.to_thread(_dashboard_reachable_on, address, bound_host, bound_port):
        raise HTTPException(status_code=503, detail="The dashboard is not reachable through the tailnet address.")
    # Alice's dashboard login sends this address as its Host header; record it once.
    if not (_cfg_get(_load_config(), "dashboard", "public_url", default="") or "").strip():
        await asyncio.to_thread(_set_dashboard_key, "public_url", f"http://{address}:{bound_port}")

    if (env.get("API_SERVER_HOST") or "").strip().strip("[]").lower() in {"127.0.0.1", "localhost", ""}:
        await asyncio.to_thread(_ensure_tailscale_forward, gateway_port)
    probe_address = "127.0.0.1" if await asyncio.to_thread(_forwards_to_loopback, gateway_port) else address
    if not await asyncio.to_thread(_main_gateway_running, profile):
        await asyncio.to_thread(_await_gateway_socket, probe_address, gateway_port)
    await asyncio.to_thread(_probe_gateway, probe_address, gateway_port, key)

    from hermes_cli.config import get_env_value_prefer_dotenv

    config: Dict[str, Any] = {
        "profile": profile,
        "gateway": {"url": f"http://{address}:{gateway_port}", "key": key},
        "dashboard": None,
    }
    username = get_env_value_prefer_dotenv("HERMES_DASHBOARD_BASIC_AUTH_USERNAME")
    password = get_env_value_prefer_dotenv("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD")
    if username and password:
        config["dashboard"] = {"url": f"http://{address}:{bound_port}", "username": username, "password": password}
    return config, address


def _gc_offers_locked(now: float) -> None:
    for token in [t for t, entry in _offers.items() if entry["expires_at"] <= now]:
        del _offers[token]


def _tombstone(entry: Dict[str, Any]) -> Dict[str, Any]:
    return {key: entry[key] for key in ("expires_at", "ip", "profile", "created_at")} | {"used": True}


def _sanitize_device_name(raw: Optional[str]) -> str:
    if not raw or not raw.strip():
        return "iPhone"
    cleaned = "".join(ch for ch in raw.strip() if ord(ch) >= 32 and ord(ch) != 127)
    return cleaned[:64] or "iPhone"


async def _read_body_limited(request: Request, limit: int) -> Optional[bytes]:
    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            return None
        chunks.append(chunk)
    return b"".join(chunks)


class _ClaimBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    token: Optional[str] = Field(default=None, max_length=512)
    device_name: Optional[str] = Field(default=None, max_length=256)


def _bearer(request: Request) -> str:
    header = request.headers.get("authorization") or ""
    return header[7:].strip() if header[:7].lower() == "bearer " else ""


@router.post("/pairing/session")
async def create_pairing_session(request: Request) -> JSONResponse:
    """Mint one short-lived pairing offer. Behind the dashboard's own login."""
    try:
        config, profile, address, display_name = await _build_pairing_config(request)
    except HTTPException:
        raise
    except Exception:  # noqa: BLE001
        _log.exception("alice pairing: config assembly failed")
        raise HTTPException(status_code=503, detail="Could not assemble the pairing configuration.") from None

    token = secrets.token_urlsafe(24)
    now = time.time()
    expires_at = int(now) + OFFER_TTL_SECONDS
    bound_port = _valid_port(getattr(request.app.state, "bound_port", 9119)) or 9119
    offer = {"c": f"http://{address}:{bound_port}{CLAIM_PATH}", "t": token, "e": expires_at, "pr": profile}
    ip = _source_ip(request)
    with _lock:
        _gc_offers_locked(now)
        # A new code replaces the previous live one from the same dashboard peer.
        for old_token, entry in list(_offers.items()):
            if not entry["used"] and entry["ip"] == ip and entry["profile"] == profile:
                del _offers[old_token]
        if sum(1 for e in _offers.values() if e["ip"] == ip and not e["used"]) >= MAX_PENDING_PER_IP:
            raise HTTPException(status_code=429, detail="Too many pending pairing codes. Use one or let it expire.")
        if len(_offers) >= MAX_PENDING_OFFERS:
            raise HTTPException(status_code=429, detail="Too many pairing sessions are pending.")
        _offers[token] = {"expires_at": expires_at, "config": config, "used": False,
                          "ip": ip, "profile": profile, "created_at": now}
    _log.info("alice pairing: session created (profile=%s)", profile)
    from datetime import datetime, timezone

    return JSONResponse(
        {"payload": _build_pairing_link(offer), "profile": profile, "profile_display_name": display_name,
         "expires_at": datetime.fromtimestamp(expires_at, tz=timezone.utc).isoformat()},
        headers=_NO_STORE,
    )


@router.post("/pairing/claim")
async def claim_pairing(request: Request) -> JSONResponse:
    """Exchange the QR's one-time code for long-lived configuration."""
    ip = _source_ip(request)
    if _has_forwarding_headers(request) or not _origin_allowed(ip):
        return JSONResponse({"error": "forbidden"}, status_code=403, headers=_NO_STORE)
    if _claim_rate_limited(ip):
        return JSONResponse({"error": "rate_limited"}, status_code=429, headers=_NO_STORE)
    body = await _read_body_limited(request, CLAIM_BODY_MAX_BYTES)
    try:
        parsed = _ClaimBody.model_validate(json.loads(body or b"{}"))
    except Exception:  # noqa: BLE001 — every bad body is simply unknown
        return JSONResponse({"error": "unknown"}, status_code=404, headers=_NO_STORE)
    # The seam authenticated the bearer; a body token must name the same code.
    token = _bearer(request)
    if not token or (parsed.token and not secrets.compare_digest(parsed.token, token)):
        return JSONResponse({"error": "unknown"}, status_code=404, headers=_NO_STORE)

    now = time.time()
    config: Optional[Dict[str, Any]] = None
    with _lock:
        entry = _offers.get(token)
        if entry is None:
            outcome = "unknown"
        elif entry["used"]:
            outcome = "used"
        elif entry["expires_at"] <= now:
            del _offers[token]
            outcome = "expired"
        elif entry.get("config") is None:
            outcome = "unknown"
        else:
            config = entry["config"]
            _offers[token] = _tombstone(entry)
            outcome = "ok"
    if outcome != "ok":
        status = 410 if outcome in ("used", "expired") else 404
        return JSONResponse({"error": outcome}, status_code=status, headers=_NO_STORE)
    _log.info("alice pairing: claimed by %s", _sanitize_device_name(parsed.device_name))
    return JSONResponse(config, headers=_NO_STORE)


# --- Curated memory ------------------------------------------------------------------------

def _known_profile(profile: str) -> str:
    name = (profile or "default").strip() or "default"
    if not any(getattr(p, "name", None) == name for p in _list_profiles()):
        raise HTTPException(status_code=404, detail=f"Unknown Hermes profile '{name}'.")
    return name


def _memory_payload(store) -> Dict[str, Any]:
    from tools.memory_tool_store import ENTRY_DELIMITER

    provider = str(_cfg_get(_load_config(), "memory", "provider", default="") or "").strip()

    def target_payload(target: str, label: str) -> Dict[str, Any]:
        entries = list(store._entries_for(target))
        return {"id": target, "label": label, "enabled": bool(store.target_enabled(target)),
                "entries": entries, "used": len(ENTRY_DELIMITER.join(entries)),
                "limit": int(store._char_limit(target))}

    return {"provider": provider,
            "targets": [target_payload("user", "User profile"), target_payload("memory", "Agent notes")]}


def _memory_snapshot(profile: str) -> Dict[str, Any]:
    from tools.memory_tool import load_on_disk_store

    with _profile_scope(profile):
        return _memory_payload(load_on_disk_store())


class _MemoryMutation(BaseModel):
    model_config = ConfigDict(extra="forbid")

    profile: str = "default"
    target: str
    action: str
    content: str = ""
    old_text: str = ""


def _mutate_memory(body: _MemoryMutation) -> Dict[str, Any]:
    action = body.action.strip().lower()
    target = body.target.strip().lower()
    if action not in {"add", "replace", "remove"}:
        raise HTTPException(status_code=400, detail="action must be add, replace, or remove")
    if target not in {"memory", "user"}:
        raise HTTPException(status_code=400, detail="target must be memory or user")
    from tools.memory_tool import load_on_disk_store

    with _profile_scope(body.profile):
        store = load_on_disk_store()
        if not store.target_enabled(target):
            raise HTTPException(status_code=400, detail=f"Built-in {target} memory is disabled for this profile")
        if action == "add":
            result = store.add(target, body.content)
        elif action == "replace":
            result = store.replace(target, body.old_text, body.content)
        else:
            result = store.remove(target, body.old_text)
        if not result.get("success"):
            raise HTTPException(status_code=400, detail=str(result.get("error") or "Memory write failed"))
        return {**_memory_payload(store), "mutation": result}


@router.get("/memory")
async def get_memory(profile: str = "default") -> Dict[str, Any]:
    name = await asyncio.to_thread(_known_profile, profile)
    return await asyncio.to_thread(_memory_snapshot, name)


@router.post("/memory")
async def mutate_memory(body: _MemoryMutation) -> Dict[str, Any]:
    body.profile = await asyncio.to_thread(_known_profile, body.profile)
    return await asyncio.to_thread(_mutate_memory, body)


# --- Notes: the store an agent keeps in its workspace ------------------------------------

NOTES_STORE = Path("workspace") / "inbox-store"
NOTE_MAX_BYTES = 64_000
NOTES_LIMIT_MAX = 2000
# The styled copy of an edited note, as base64 RTF. Generous for formatting, not for media.
NOTE_RICH_MAX_BYTES = 2_000_000
_URL = re.compile(r"https?://[^\s<>\"')\]]+")


def _notes_store_choice_path() -> Path:
    return _engine_home() / ".alice" / "notes_store.json"


def _remembered_notes_profile() -> Optional[str]:
    try:
        data = json.loads(_notes_store_choice_path().read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError, TypeError):
        return None
    name = data.get("profile") if isinstance(data, dict) else None
    return str(name) if name else None


def _save_notes_store_choice(profile: str) -> None:
    path = _notes_store_choice_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"profile": profile}), encoding="utf-8")


def _notes_store() -> Optional[Tuple[str, Path]]:
    """The profile keeping a notes store, and the store's folder.

    Prefers a profile Alice already chose (``~/.hermes/.alice/notes_store.json``),
    then ``inbox``, then the first profile that has a store. None when no agent
    keeps notes. The choice is rewritten when the remembered profile is gone.
    """
    found: List[Tuple[str, Path]] = []
    for profile in _list_profiles():
        home = getattr(profile, "path", None)
        if not home:
            continue
        root = Path(home) / NOTES_STORE
        if (root / "inbox.py").is_file():
            found.append((str(profile.name), root))
    if not found:
        return None
    remembered = _remembered_notes_profile()
    if remembered:
        match = next((item for item in found if item[0] == remembered), None)
        if match:
            return match
    chosen = next((item for item in found if item[0] == "inbox"), found[0])
    if remembered != chosen[0]:
        _save_notes_store_choice(chosen[0])
    return chosen


def _read_jsonl(path: Path) -> List[Dict[str, Any]]:
    """Rows of an append-only JSONL file; a torn or foreign line is skipped, never repaired."""
    rows: List[Dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(row, dict):
                    rows.append(row)
    except FileNotFoundError:
        pass
    return rows


def _note_payload(entry: Dict[str, Any], extra: Dict[str, Any]) -> Dict[str, Any]:
    def strings(value: Any) -> List[str]:
        return [str(item) for item in value if str(item).strip()] if isinstance(value, list) else []

    return {
        "id": str(entry.get("id")),
        "ts": str(entry.get("ts") or ""),
        "text": str(entry.get("text") or ""),
        "urls": strings(entry.get("urls")),
        # The agent's own reading wins over the store's first guess at capture.
        "types": strings(extra.get("types")) or strings(entry.get("heuristic_types")),
        "topics": strings(extra.get("topics")),
        "actions": strings(extra.get("actions")),
        "open_questions": strings(extra.get("open_questions")),
        "summary": str(extra.get("summary") or ""),
        "status": str(extra.get("status") or ""),
        "processed": bool(extra.get("processed")),
        # Where it is filed and what it is about, as its agent or the person set.
        "folder": str(extra.get("folder") or "") or None,
        "tags": strings(extra.get("tags")),
        # Written in Alice's editor: the styled copy, and when it was last changed.
        "rich": str(entry.get("rich_rtf") or "") or None,
        "edited_ts": str(entry.get("edited_ts") or "") or None,
    }


def _notes_snapshot(limit: int) -> Dict[str, Any]:
    store = _notes_store()
    if store is None:
        return {"available": False, "notes": [], "total": 0}
    profile, root = store
    enrichment: Dict[str, Dict[str, Any]] = {}
    for row in _read_jsonl(root / "enrichment.jsonl"):
        if row.get("id"):
            enrichment[str(row["id"])] = row  # the last record for an id wins
    entries = [row for row in _read_jsonl(root / "entries.jsonl")
               if row.get("id") and isinstance(row.get("text"), str)]
    entries.reverse()
    folders = _note_folders(root)
    known = {folder["id"] for folder in folders}
    notes = [_note_payload(row, enrichment.get(str(row["id"]), {})) for row in entries[:limit]]
    for note in notes:
        # A folder that is gone leaves its notes in Quick Notes.
        if note["folder"] not in known:
            note["folder"] = None
    return {"available": True, "profile": profile, "total": len(entries),
            "folders": folders, "notes": notes}


def _note_folders(root: Path) -> List[Dict[str, Any]]:
    """The store's folders, in the order they were made."""
    try:
        data = json.loads((root / "folders.json").read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    rows = data.get("folders") if isinstance(data, dict) else None
    return [{"id": str(row["id"]), "name": str(row["name"])}
            for row in rows or [] if isinstance(row, dict) and row.get("id") and row.get("name")]


def _run_store(root: Path, *args: str) -> Dict[str, Any]:
    """One `inbox.py` command against the store, so folders keep the store's own rules and locks."""
    try:
        result = subprocess.run(
            [sys.executable, str(root / "inbox.py"), *args],
            capture_output=True, text=True, timeout=20,
            env={**os.environ, "INBOX_STORE": str(root)},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HTTPException(status_code=502, detail="The notes store did not answer.") from exc
    try:
        reply = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        reply = {}
    if result.returncode != 0 or not isinstance(reply, dict) or not reply.get("ok"):
        detail = reply.get("error") if isinstance(reply, dict) else None
        status = 404 if result.returncode == 2 else 502
        raise HTTPException(status_code=status, detail=str(detail or "The notes store refused that."))
    return reply


def _store_or_404() -> Tuple[str, Path]:
    store = _notes_store()
    if store is None:
        raise HTTPException(status_code=404, detail="No agent on this Hermes keeps a notes store.")
    return store


class _NewNote(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str


def _add_note(text: str) -> Dict[str, Any]:
    if not text.strip():
        raise HTTPException(status_code=400, detail="A note needs some text.")
    if len(text.encode("utf-8")) > NOTE_MAX_BYTES:
        raise HTTPException(status_code=413, detail="That note is too long.")
    store = _notes_store()
    if store is None:
        raise HTTPException(status_code=404, detail="No agent on this Hermes keeps a notes store.")
    profile, root = store
    try:
        # Text on stdin and no shell: the note is data, whatever it says.
        result = subprocess.run(
            [sys.executable, str(root / "inbox.py"), "add", "--stdin"],
            input=text, capture_output=True, text=True, timeout=20,
            env={**os.environ, "INBOX_STORE": str(root)},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HTTPException(status_code=502, detail="The notes store did not answer.") from exc
    try:
        reply = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        reply = {}
    if result.returncode != 0 or not isinstance(reply, dict) or not reply.get("ok"):
        detail = reply.get("error") if isinstance(reply, dict) else None
        raise HTTPException(status_code=502, detail=str(detail or "The notes store did not save the note."))
    saved = str(reply.get("id") or "")
    entry = next((row for row in reversed(_read_jsonl(root / "entries.jsonl")) if row.get("id") == saved), None)
    if entry is None:
        entry = {"id": saved, "ts": reply.get("ts"), "text": text, "heuristic_types": reply.get("types")}
    return {"ok": True, "profile": profile, "note": _note_payload(entry, {})}


class _EditedNote(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str
    rich: Optional[str] = None


def _edit_note(note_id: str, text: str, rich: Optional[str]) -> Dict[str, Any]:
    """Rewrites one note in place: its plain text, which agents read, and its styled copy.

    Deliberately not append-only — the person chose to edit notes rather than keep versions. The
    file is rewritten under the same ``flock`` that ``inbox.py`` takes to append, and in place
    rather than swapped for a new file, so an append waiting on the lock lands in the file that
    stays. The note's enrichment is carried forward unprocessed, so its agent sorts it again."""
    if not text.strip():
        raise HTTPException(status_code=400, detail="A note needs some text.")
    if len(text.encode("utf-8")) > NOTE_MAX_BYTES:
        raise HTTPException(status_code=413, detail="That note is too long.")
    if rich is not None:
        if len(rich) > NOTE_RICH_MAX_BYTES:
            raise HTTPException(status_code=413, detail="That note's formatting is too large.")
        try:
            base64.b64decode(rich, validate=True)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="The note's formatting is not readable.") from exc
    store = _notes_store()
    if store is None:
        raise HTTPException(status_code=404, detail="No agent on this Hermes keeps a notes store.")
    profile, root = store
    path = root / "entries.jsonl"
    # The store's own shape: local time with its offset, `2026-09-14T09:00:00+02:00`.
    from datetime import datetime
    edited = datetime.now().astimezone().isoformat(timespec="seconds")
    try:
        with path.open("r+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            lines = handle.read().splitlines(keepends=True)
            updated: Optional[Dict[str, Any]] = None
            for index, line in enumerate(lines):
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict) or str(row.get("id")) != note_id:
                    continue
                row["text"] = text
                row["urls"] = _URL.findall(text)
                row["bytes"] = len(text.encode("utf-8"))
                row["edited_ts"] = edited
                if rich:
                    row["rich_rtf"] = rich
                else:
                    row.pop("rich_rtf", None)
                lines[index] = json.dumps(row, ensure_ascii=False) + "\n"
                updated = row
                break
            if updated is None:
                raise HTTPException(status_code=404, detail="That note is no longer in the store.")
            handle.seek(0)
            handle.write("".join(lines))
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="That note is no longer in the store.") from exc
    enrichment: Dict[str, Any] = {}
    for row in _read_jsonl(root / "enrichment.jsonl"):
        if str(row.get("id")) == note_id:
            enrichment = row
    if enrichment.get("processed"):
        carried = {**enrichment, "id": note_id, "processed": False, "edited_ts": edited}
        with (root / "enrichment.jsonl").open("a", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            handle.write(json.dumps(carried, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        enrichment = carried
    return {"ok": True, "profile": profile, "note": _note_payload(updated, enrichment)}


def _rewrite_jsonl(path: Path, keep) -> int:
    """Rewrites a JSONL file in place under ``flock`` with only the rows ``keep`` accepts; lines
    that are not JSON objects are kept as they are. Returns how many rows were dropped."""
    try:
        handle = path.open("r+", encoding="utf-8")
    except FileNotFoundError:
        return 0
    with handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        kept: List[str] = []
        dropped = 0
        for line in handle.read().splitlines(keepends=True):
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                kept.append(line)
                continue
            if isinstance(row, dict) and not keep(row):
                dropped += 1
            else:
                kept.append(line)
        if dropped:
            handle.seek(0)
            handle.write("".join(kept))
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
        return dropped


def _delete_note(note_id: str) -> Dict[str, Any]:
    """Deletes one note for good: its entry, its agent's reading of it and its relations."""
    store = _notes_store()
    if store is None:
        raise HTTPException(status_code=404, detail="No agent on this Hermes keeps a notes store.")
    profile, root = store
    if not _rewrite_jsonl(root / "entries.jsonl", lambda row: str(row.get("id")) != note_id):
        raise HTTPException(status_code=404, detail="That note is no longer in the store.")
    _rewrite_jsonl(root / "enrichment.jsonl", lambda row: str(row.get("id")) != note_id)
    _rewrite_jsonl(root / "relations.jsonl",
                   lambda row: note_id not in (str(row.get("a")), str(row.get("b"))))
    return {"ok": True, "profile": profile, "deleted": note_id}


@router.get("/notes")
async def get_notes(limit: int = 500) -> Dict[str, Any]:
    return await asyncio.to_thread(_notes_snapshot, max(1, min(limit, NOTES_LIMIT_MAX)))


@router.post("/notes")
async def add_note(body: _NewNote) -> Dict[str, Any]:
    return await asyncio.to_thread(_add_note, body.text)


class _FolderName(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str


class _NoteFolder(BaseModel):
    model_config = ConfigDict(extra="forbid")

    folder: Optional[str] = None


@router.post("/notes/folders")
async def create_note_folder(body: _FolderName) -> Dict[str, Any]:
    def run() -> Dict[str, Any]:
        _, root = _store_or_404()
        if not body.name.strip():
            raise HTTPException(status_code=400, detail="A folder needs a name.")
        return {"ok": True, "folder": _run_store(root, "folder-create", body.name)["folder"]}
    return await asyncio.to_thread(run)


@router.put("/notes/folders/{folder_id}")
async def rename_note_folder(folder_id: str, body: _FolderName) -> Dict[str, Any]:
    def run() -> Dict[str, Any]:
        _, root = _store_or_404()
        if not body.name.strip():
            raise HTTPException(status_code=400, detail="A folder needs a name.")
        _run_store(root, "folder-rename", folder_id, body.name)
        return {"ok": True}
    return await asyncio.to_thread(run)


@router.delete("/notes/folders/{folder_id}")
async def delete_note_folder(folder_id: str) -> Dict[str, Any]:
    def run() -> Dict[str, Any]:
        _, root = _store_or_404()
        _run_store(root, "folder-delete", folder_id)
        return {"ok": True}
    return await asyncio.to_thread(run)


@router.put("/notes/{note_id}/folder")
async def file_note(note_id: str, body: _NoteFolder) -> Dict[str, Any]:
    def run() -> Dict[str, Any]:
        _, root = _store_or_404()
        reply = _run_store(root, "file", note_id, "--folder", body.folder or "none")
        return {"ok": True, "folder": reply.get("folder")}
    return await asyncio.to_thread(run)


@router.delete("/notes/{note_id}")
async def delete_note(note_id: str) -> Dict[str, Any]:
    return await asyncio.to_thread(_delete_note, note_id)


@router.put("/notes/{note_id}")
async def edit_note(note_id: str, body: _EditedNote) -> Dict[str, Any]:
    return await asyncio.to_thread(_edit_note, note_id, body.text, body.rich)


# --- Shared agent create / rename (Alice form and Agent Maker) -----------------------------

def _agent_engine():
    import importlib.util

    path = Path(__file__).resolve().parents[1] / "agent_engine.py"
    name = "alice_agent_engine"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _engine_home() -> Path:
    try:
        from hermes_cli.config import get_process_hermes_home
        return Path(get_process_hermes_home())
    except Exception:
        return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


class _AgentCreateBody(BaseModel):
    model_config = ConfigDict(extra="allow")

    title: Optional[str] = None
    name: Optional[str] = None
    description: str = ""
    soul: Optional[str] = None
    tools: Optional[List[str]] = None
    routines: Optional[List[Dict[str, Any]]] = None
    model: Optional[Any] = None
    provider: Optional[str] = None
    fallback: Optional[List[Any]] = None
    reuse_profile: Optional[str] = None
    job_id: Optional[str] = None
    memory: Optional[str] = None
    copy_memory: bool = False
    source: Optional[str] = None
    smoke: bool = False


class _AgentRenameBody(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    from_profile: str = Field(alias="from")
    to: str
    job_id: Optional[str] = None
    busy: bool = False


def _create_agent_payload(body: Dict[str, Any]) -> Dict[str, Any]:
    engine = _agent_engine()
    try:
        return engine.create_agent(
            body,
            home=_engine_home(),
            require_soul=bool(str(body.get("soul") or "").strip()),
            job_id=str(body.get("job_id") or "") or None,
        )
    except engine.SpecError as exc:
        return engine.result(engine.STATUS_FAILED, error=str(exc))


def _rename_agent_payload(body: _AgentRenameBody) -> Dict[str, Any]:
    engine = _agent_engine()
    return engine.rename_agent(
        body.from_profile,
        body.to,
        home=_engine_home(),
        job_id=body.job_id,
        busy_profiles=[body.from_profile] if body.busy else None,
    )


@router.post("/agents")
async def create_agent(body: _AgentCreateBody) -> Dict[str, Any]:
    payload = await asyncio.to_thread(_create_agent_payload, body.model_dump(exclude_none=True))
    return payload


@router.post("/agents/rename")
async def rename_agent(body: _AgentRenameBody) -> Dict[str, Any]:
    return await asyncio.to_thread(_rename_agent_payload, body)


@router.get("/agents/jobs/{job_id}")
async def agent_job(job_id: str) -> Dict[str, Any]:
    engine = _agent_engine()
    try:
        found = engine.load_journal(job_id, _engine_home())
    except engine.SpecError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    if not found:
        raise HTTPException(status_code=404, detail="No agent operation with that id.")
    return found


_register_claim_auth()
