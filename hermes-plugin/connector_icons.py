"""Each connector's own logo, read from the product's own website.

The Hermes MCP catalog names its connectors but carries no artwork. Hermes' desktop app
resolves one the same way this does: the product's own site first (the only source that
is certainly the right mark), then the endpoint it talks to, then its docs — and never a
public icon service, since asking one would tell a third party which connector someone
is setting up. A site that cannot be read keeps its initial on the phone.

What is found is kept in ``<hermes home>/.alice/connector-icons`` for a month, so a site
is asked once, not on every visit to Settings. Only raster images are kept (PNG, ICO,
JPEG, WebP): the phone draws them directly.
"""
from __future__ import annotations

import html.parser
import ipaddress
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Iterable, List, Optional, Tuple

CACHE = Path(".alice") / "connector-icons"
KEEP_SECONDS = 30 * 86_400
# A logo that was not found is asked for again after a day, not every time.
MISS_SECONDS = 86_400
MAX_BYTES = 512 * 1024
TIMEOUT = 6.0
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
RASTER = {"image/png": "png", "image/x-icon": "ico", "image/vnd.microsoft.icon": "ico",
          "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif"}
# A bridge published on GitHub is not GitHub; a package page is not the product.
NOT_A_LOGO = re.compile(r"(^|\.)(github\.com|githubusercontent\.com|gitlab\.com|bitbucket\.org|npmjs\.com|"
                        r"pypi\.org|readthedocs\.io|modelcontextprotocol\.io)$")
NAME = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")


def _private(host: str) -> bool:
    if host in ("localhost",) or host.endswith(".local") or host.endswith(".internal"):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.is_private or address.is_loopback or address.is_link_local


def sites(hosts: Iterable[str], urls: Iterable[str], name: str = "") -> List[str]:
    """Origins to read a mark from, best first: the product's own hosts, then each URL's
    host, then that host without its first label (``mcp.linear.app`` → ``linear.app``).
    A code host is a logo only for its own connector: GitLab's is gitlab.com."""
    found: List[str] = []
    own = re.sub(r"[^a-z0-9]", "", (name or "").lower())

    def add(host: str) -> None:
        host = (host or "").strip().lower().strip(".")
        if not host or _private(host):
            return
        if NOT_A_LOGO.search(host) and not (own and host.split(".")[-2:-1] == [own]):
            return
        origin = f"https://{host}"
        if origin not in found:
            found.append(origin)

    for host in hosts:
        add(host)
    parsed = []
    for url in urls:
        try:
            parsed.append(urllib.parse.urlsplit(url or "").hostname or "")
        except ValueError:
            continue
    for host in parsed:
        add(host)
    for host in parsed:
        parts = host.split(".")
        # A name, not an address: 192.168.1.4 has no "site above it".
        if len(parts) > 2 and not _private(host) and not all(p.isdigit() for p in parts):
            add(".".join(parts[1:]))
    return found


class _IconLinks(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: List[Tuple[str, str, str]] = []  # rel, href, sizes

    def handle_starttag(self, tag, attrs):
        if tag != "link":
            return
        values = {k.lower(): (v or "") for k, v in attrs}
        rel = values.get("rel", "").lower()
        if "icon" in rel and values.get("href"):
            self.links.append((rel, values["href"], values.get("sizes", "")))


def candidates(page: str, origin: str) -> List[str]:
    """Icon URLs a page declares, best first: apple-touch icons (made to be shown at
    phone size), then sized PNGs large to small, then the rest; SVG is skipped, then the
    well-known paths."""
    parser = _IconLinks()
    try:
        parser.feed(page or "")
    except Exception:  # noqa: BLE001 — a malformed page just has no declared icons
        pass

    def score(link: Tuple[str, str, str]) -> int:
        rel, href, sizes = link
        edge = max((int(n) for n in re.findall(r"(\d+)x\d+", sizes)), default=0)
        if href.lower().split("?")[0].endswith(".svg") or "mask-icon" in rel:
            return -1
        if "apple-touch-icon" in rel:
            return 2000 + edge
        return edge or 100

    ranked = sorted((l for l in parser.links if score(l) >= 0), key=score, reverse=True)
    urls = [urllib.parse.urljoin(origin + "/", href) for _, href, _ in ranked]
    for path in ("/apple-touch-icon.png", "/favicon.ico"):
        url = origin + path
        if url not in urls:
            urls.append(url)
    return urls


def _fetch(url: str, limit: int) -> Tuple[bytes, str]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310 — https origins only
        final = urllib.parse.urlsplit(response.geturl())
        if final.scheme != "https" or _private(final.hostname or ""):
            raise ValueError("redirected somewhere it should not go")
        kind = (response.headers.get_content_type() or "").lower()
        return response.read(limit + 1), kind


def _sniff(data: bytes) -> Optional[str]:
    if data.startswith(b"\x89PNG"):
        return "image/png"
    if data[:4] == b"\x00\x00\x01\x00":
        return "image/x-icon"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:4] == b"GIF8":
        return "image/gif"
    return None


def resolve(origins: List[str], fetch: Callable[[str, int], Tuple[bytes, str]] = _fetch) -> Optional[Tuple[bytes, str]]:
    """The first raster logo any of the origins offers."""
    for origin in origins:
        try:
            page, _ = fetch(origin + "/", 400_000)
            page_text = page.decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 — an unreadable site still has well-known paths
            page_text = ""
        for url in candidates(page_text, origin)[:6]:
            try:
                data, kind = fetch(url, MAX_BYTES)
            except Exception:  # noqa: BLE001
                continue
            if not data or len(data) > MAX_BYTES or len(data) < 64:
                continue
            mime = _sniff(data) or (kind if kind in RASTER else None)
            if mime in RASTER:
                return data, mime
    return None


class Icons:
    """The cache for one Hermes home."""

    def __init__(self, home: Path, now: Callable[[], float] = time.time,
                 fetch: Callable[[str, int], Tuple[bytes, str]] = _fetch):
        self.dir = Path(home) / CACHE
        self.now = now
        self.fetch = fetch

    def get(self, name: str, hosts: Iterable[str], urls: Iterable[str]) -> Optional[Tuple[bytes, str]]:
        if not NAME.match(name or ""):
            return None
        meta_path = self.dir / f"{name}.json"
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            meta = None
        if isinstance(meta, dict):
            age = self.now() - float(meta.get("at") or 0)
            if meta.get("missing") and age < MISS_SECONDS:
                return None
            if not meta.get("missing") and age < KEEP_SECONDS:
                try:
                    return (self.dir / f"{name}.{meta['ext']}").read_bytes(), meta["mime"]
                except (OSError, KeyError):
                    pass
        found = resolve(sites(hosts, urls, name), self.fetch)
        self.dir.mkdir(parents=True, exist_ok=True)
        if found is None:
            meta_path.write_text(json.dumps({"missing": True, "at": self.now()}), encoding="utf-8")
            return None
        data, mime = found
        ext = RASTER[mime]
        (self.dir / f"{name}.{ext}").write_bytes(data)
        meta_path.write_text(json.dumps({"mime": mime, "ext": ext, "at": self.now()}), encoding="utf-8")
        return found
