"""Authenticator keys for saved logins, so Alice mints the 6-digit codes herself.

Hermes already does the rest: when a saved login carries a TOTP seed, ``browser_vault_enter_code``
generates the code on the Mac and nobody is asked. What it lacks is a way to give the seed from a
phone (``vault.save_login`` takes only the email and password). When a site asks Alice for a code,
the app's code card can take the site's authenticator key (the setup key, or an ``otpauth://``
link) instead of one code; this attaches it to the saved login for that site, in Hermes' vault,
and returns the current code so this sign-in goes on at once. From then on no code is asked.

Nothing here logs or returns the key; only which sites now have one, and the one current code.
"""

from __future__ import annotations

from typing import Any, Dict, List
from urllib.parse import urlsplit


class OtpError(ValueError):
    pass


def _store():
    from agent.vault_store import get_vault_store

    return get_vault_store()


def _host(site: str) -> str:
    raw = (site or "").strip().lower()
    host = urlsplit(raw if "://" in raw else f"https://{raw}").hostname or ""
    return host[4:] if host.startswith("www.") else host


def logins_for(site: str) -> List[Any]:
    host = _host(site)
    if not host:
        return []
    return [m for m in _store().list_items() if m.kind == "login" and m.origin and _host(m.origin) == host]


def add(site: str, key: str) -> Dict[str, Any]:
    """Attach the authenticator key to every saved login for ``site``; the current code back."""
    from agent.vault_store import VaultError, normalize_otp_secret, totp_now

    try:
        seed = normalize_otp_secret(key)
    except VaultError as exc:
        raise OtpError("That is not an authenticator key: paste the setup key or the otpauth:// link.") from exc
    if not seed:
        raise OtpError("The key is empty.")
    found = logins_for(site)
    if not found:
        raise OtpError("There is no saved login for that site yet; sign in once with the secure card first.")
    store = _store()
    sites = []
    for meta in found:
        secret = store.resolve_secret(meta.id)
        store.remove_item(meta.id)
        store.add_item("login", meta.label, {
            "identifier_type": meta.identifier_type or ("email" if "@" in (meta.identifier or "") else "username"),
            "identifier": meta.identifier or "",
            "password": secret.get("password", ""),
            "otp_secret": seed,
        }, origin=meta.origin)
        sites.append(meta.origin)
    return {"sites": sites, "code": totp_now(seed)}


def status(site: str) -> Dict[str, Any]:
    found = logins_for(site)
    return {"saved_login": bool(found), "has_key": any(getattr(m, "has_otp", False) for m in found)}
