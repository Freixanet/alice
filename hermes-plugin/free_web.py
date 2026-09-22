"""Web search and page reading that cost nothing unless they have to.

Registered as the ``alice-free`` web provider and selected per agent with
``web.search_backend`` / ``web.extract_backend``. Search goes to Exa's free
public endpoint (the same one Hermes keeps as a last resort); a page is read
through Jina Reader, which is free. Only when those fail, or come back empty,
does the call go on to the paid Firecrawl backend configured in Hermes — so a
search never goes unanswered because it was cheap.

Nothing here reaches past Hermes' own public pieces: the keyless Exa helper,
the Firecrawl provider and the result shapes all come from Hermes' bundled
web plugins, imported lazily so an update that moves them degrades to the
paid path instead of breaking the tool.
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import socket
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit

logger = logging.getLogger(__name__)

NAME = "alice-free"
JINA_ENDPOINT = "https://r.jina.ai/"
JINA_TIMEOUT = 25
JINA_LIMIT = 400_000


def _public_http(url: str) -> bool:
    """Only public http(s) pages go to Jina: a private address is not its to read."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return False
    try:
        infos = socket.getaddrinfo(parts.hostname, None)
    except OSError:
        return False
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            return False
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            return False
    return True


def jina_read(url: str, fetch=None) -> Dict[str, Any]:
    """One page as Markdown through Jina Reader, in Hermes' extract shape."""
    if not _public_http(url):
        return {"url": url, "title": "", "content": "", "error": "Not a public web page."}
    request = urllib.request.Request(
        JINA_ENDPOINT + url,
        headers={"Accept": "text/plain", "X-Return-Format": "markdown", "User-Agent": "alice-hermes"},
    )
    try:
        if fetch is not None:
            status, body = fetch(request)
        else:
            with urllib.request.urlopen(request, timeout=JINA_TIMEOUT) as response:
                status, body = response.status, response.read(JINA_LIMIT)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"url": url, "title": "", "content": "", "error": f"Jina: {exc}"}
    text = body.decode("utf-8", "replace") if isinstance(body, (bytes, bytearray)) else str(body)
    if status >= 400 or not text.strip():
        return {"url": url, "title": "", "content": "", "error": f"Jina: HTTP {status}"}
    title = ""
    content = text
    marker = "Markdown Content:"
    for line in text.splitlines()[:6]:
        if line.startswith("Title:"):
            title = line[len("Title:"):].strip()
    if marker in text:
        content = text.split(marker, 1)[1].strip()
    if len(content) < 200:
        # A login wall, a cookie page or a script-only shell: not worth passing on.
        return {"url": url, "title": title, "content": "", "error": "Jina: page came back nearly empty."}
    return {
        "url": url, "title": title, "content": content, "raw_content": content,
        "metadata": {"sourceURL": url, "title": title, "reader": "jina"},
    }


def _paid_provider():
    """Hermes' own Firecrawl provider, the paid fallback — or None."""
    try:
        from plugins.web.firecrawl.provider import FirecrawlWebSearchProvider
    except Exception:  # noqa: BLE001 — moved in a Hermes update: no fallback, not a crash
        return None
    provider = FirecrawlWebSearchProvider()
    try:
        return provider if provider.is_available() else None
    except Exception:  # noqa: BLE001
        return None


def _build_provider_class():
    from agent.web_search_provider import WebSearchProvider

    class AliceFreeWebProvider(WebSearchProvider):
        @property
        def name(self) -> str:
            return NAME

        @property
        def display_name(self) -> str:
            return "Alice (free first)"

        def is_available(self) -> bool:
            return True

        def supports_search(self) -> bool:
            return True

        def supports_extract(self) -> bool:
            return True

        def get_setup_schema(self) -> Dict[str, Any]:
            return {"name": self.display_name, "badge": "free", "tag": "Exa free search, Jina reading; Firecrawl only as fallback", "env_vars": []}

        def search(self, query: str, limit: int = 5) -> Dict[str, Any]:
            try:
                from plugins.web.keyless_mcp import exa_search_keyless
                result = exa_search_keyless(query, limit)
                if result.get("success") and ((result.get("data") or {}).get("web")):
                    return result
                reason = result.get("error") or "no results"
            except Exception as exc:  # noqa: BLE001
                reason = str(exc)
            logger.info("alice-free: Exa free search fell through (%s); using the paid backend", reason)
            paid = _paid_provider()
            if paid is None:
                return {"success": False, "error": f"Free search failed ({reason}) and no paid backend is set."}
            return paid.search(query, limit)

        async def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
            pages = await asyncio.gather(*(asyncio.to_thread(jina_read, url) for url in urls))
            failed = [page["url"] for page in pages if page.get("error")]
            if not failed:
                return list(pages)
            paid = _paid_provider()
            if paid is None:
                return list(pages)
            logger.info("alice-free: %d page(s) not readable for free; using the paid backend", len(failed))
            retried = {page.get("url"): page for page in await paid.extract(failed, **kwargs)}
            return [retried.get(page["url"], page) if page.get("error") else page for page in pages]

    return AliceFreeWebProvider


def register(ctx) -> None:
    """Adds the provider; it is used only by agents whose config selects it."""
    register_provider = getattr(ctx, "register_web_search_provider", None)
    if register_provider is None:
        return
    try:
        register_provider(_build_provider_class()())
    except Exception as exc:  # noqa: BLE001 — a web provider must never stop the plugin loading
        logger.warning("alice-free web provider not registered: %s", exc)
