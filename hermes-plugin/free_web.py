"""Web search and page reading that cost nothing unless they have to.

Registered as the ``alice-free`` web provider and selected per agent with
``web.search_backend`` / ``web.extract_backend``. Search goes to Exa: with the
person's own ``EXA_API_KEY`` when there is one (Exa's free tier), otherwise
to its keyless public endpoint (the same one Hermes keeps as a last resort),
which rate-limits hard and on its own leaves search dead; a page is read
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
import json
import logging
import os
import socket
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit

logger = logging.getLogger(__name__)

NAME = "alice-free"
JINA_ENDPOINT = "https://r.jina.ai/"
EXA_ENDPOINT = "https://api.exa.ai/search"
EXA_TIMEOUT = 20
SNIPPET = 600
JINA_TIMEOUT = 25
JINA_LIMIT = 400_000
# Jina's free tier turns away bursts: a few pages at a time, one retry each.
JINA_CONCURRENCY = 3
RETRY_PAUSE = 1.2


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


KEY_NAME = "EXA_API_KEY"
KEY_OFFER = (
    "Do not ask for the key in the chat. Say in one sentence that search needs a free Exa key "
    "and end your reply with this line alone: [Conectar búsqueda](alice://connect/search) "
    "(English replies: [Turn on search](alice://connect/search)). Alice asks for the key in a secure field "
    "and saves it to Hermes; when the person says it is done, search again."
)


# Retrying the same search through execute_code or the terminal reaches the
# same backend, fails the same way, and costs the person an approval prompt.
NO_RETRY = (
    "Do not retry this search through execute_code, the terminal or another tool: it reaches the same "
    "search and fails the same way. Answer with what you know, say plainly that search is down, and stop."
)


def _env_file_value(path, name: str) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    for raw in lines:
        line = raw.strip()
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if not line.startswith(name + "="):
            continue
        return line[len(name) + 1:].strip().strip("\"'")
    return ""


def exa_key() -> str:
    """The person's Exa key: the process environment, else this profile's .env, else the main one.

    Read at every search, so a key saved from Alice works without restarting Hermes.
    """
    key = os.environ.get(KEY_NAME, "").strip()
    if key:
        return key
    try:
        from pathlib import Path
        from hermes_constants import get_default_hermes_root, get_hermes_home
    except Exception:  # noqa: BLE001 — outside Hermes: no files to read
        return ""
    for root in (get_hermes_home(), get_default_hermes_root()):
        try:
            value = _env_file_value(Path(root) / ".env", KEY_NAME)
        except Exception:  # noqa: BLE001
            value = ""
        if value:
            return value
    return ""


def exa_search_keyed(query: str, limit: int, key: str, fetch=None) -> Dict[str, Any]:
    """Exa search with the person's own key, in Hermes' search shape."""
    body = json.dumps({
        "query": query, "numResults": max(1, min(int(limit or 5), 10)), "type": "auto",
        "contents": {"text": {"maxCharacters": SNIPPET}},
    }).encode()
    request = urllib.request.Request(
        EXA_ENDPOINT, data=body, method="POST",
        headers={"Content-Type": "application/json", "x-api-key": key, "User-Agent": "alice-hermes"},
    )
    try:
        if fetch is not None:
            status, raw = fetch(request)
        else:
            with urllib.request.urlopen(request, timeout=EXA_TIMEOUT) as response:
                status, raw = response.status, response.read()
    except urllib.error.HTTPError as exc:
        return {"success": False, "error": f"Exa: HTTP {exc.code}"}
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"success": False, "error": f"Exa: {exc}"}
    if status >= 400:
        return {"success": False, "error": f"Exa: HTTP {status}"}
    try:
        results = json.loads(raw).get("results") or []
    except (ValueError, AttributeError):
        return {"success": False, "error": "Exa: unreadable reply"}
    web = [
        {"url": item["url"], "title": item.get("title") or "",
         "description": " ".join(str(item.get("text") or "").split())[:SNIPPET]}
        for item in results if isinstance(item, dict) and item.get("url")
    ]
    return {"success": True, "data": {"web": web}}


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
            reason = "no results"
            key = exa_key()
            if key:
                result = exa_search_keyed(query, limit, key)
                if result.get("success") and result["data"]["web"]:
                    return result
                reason = result.get("error") or "no results"
                logger.info("alice-free: Exa with the person's key fell through (%s)", reason)
            # Twice: the free endpoint sheds load with an odd reply now and then.
            for attempt in range(2):
                try:
                    from plugins.web.keyless_mcp import exa_search_keyless
                    result = exa_search_keyless(query, limit)
                    if result.get("success") and ((result.get("data") or {}).get("web")):
                        return result
                    reason = result.get("error") or "no results"
                except Exception as exc:  # noqa: BLE001
                    reason = str(exc)
                if attempt == 0:
                    time.sleep(RETRY_PAUSE)
            logger.info("alice-free: Exa free search fell through (%s); using the paid backend", reason)
            paid = _paid_provider()
            if paid is None:
                if key:
                    return {"success": False, "error": f"Search failed ({reason}) and no paid backend is set. " + NO_RETRY}
                return {"success": False, "error": (
                    f"Search failed ({reason}): Exa's keyless endpoint is rate-limited and no paid backend is set. "
                    + KEY_OFFER + " " + NO_RETRY
                )}
            return paid.search(query, limit)

        async def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
            gate = asyncio.Semaphore(JINA_CONCURRENCY)

            async def read(url: str) -> Dict[str, Any]:
                async with gate:
                    page = await asyncio.to_thread(jina_read, url)
                    if page.get("error") and "public web page" not in page["error"]:
                        await asyncio.sleep(RETRY_PAUSE)
                        page = await asyncio.to_thread(jina_read, url)
                    return page

            pages = await asyncio.gather(*(read(url) for url in urls))
            failed = [page["url"] for page in pages if page.get("error")]
            for page in pages:
                if page.get("error"):
                    # The host and the reason only: never the page or the query.
                    logger.info("alice-free: Jina could not read %s (%s)", urlsplit(page["url"]).hostname, page["error"][:80])
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
