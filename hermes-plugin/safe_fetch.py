"""Fetching a page or picture the agent or a web page chose, without reaching inside the Mac.

An icon or product-picture address comes from a web page or the model. Fetched as is, it could
point at the Mac itself (the browser's debugging port, the dashboard), the home network or the
tailnet, and the plugin would read it for them. Every request and every redirect is checked first:
https only, and a host that resolves to public addresses only (Hermes' own ``is_safe_url`` when it
is there, the same rule here when it is not).
"""

from __future__ import annotations

import ipaddress
import socket
import urllib.parse
import urllib.request
from typing import Dict, Tuple


def _public(host: str) -> bool:
    try:
        answers = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
    except (OSError, UnicodeError):
        return False
    addresses = {a[4][0] for a in answers}
    return bool(addresses) and all(ipaddress.ip_address(a.split("%")[0]).is_global for a in addresses)


def safe(url: str) -> bool:
    parts = urllib.parse.urlsplit(str(url or ""))
    if parts.scheme != "https" or not parts.hostname:
        return False
    try:
        from tools.url_safety import is_safe_url

        if not is_safe_url(url):
            return False
    except ImportError:
        pass
    # Hermes allows the tailnet (100.64.0.0/10 is not "private" to Python); this does not.
    return _public(parts.hostname)


class _Checked(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not safe(newurl):
            raise ValueError("redirected somewhere it should not go")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_Checked)


def fetch(url: str, headers: Dict[str, str], limit: int, timeout: float) -> Tuple[bytes, str]:
    """(the first ``limit`` bytes, content type); ValueError when the address is not allowed."""
    if not safe(url):
        raise ValueError("not a public https address")
    request = urllib.request.Request(url, headers=headers)
    with _opener.open(request, timeout=timeout) as response:
        return response.read(limit), str(response.headers.get("Content-Type") or "")
