"""Read-only, bounded sources. Source payloads never choose tools or credentials."""
from __future__ import annotations

import hashlib
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit, urlencode, unquote
import posixpath


class SourceError(ValueError):
    pass


def validate(source, config):
    if source not in ("email", "feed", "github", "builtin") or not isinstance(config, dict):
        raise SourceError("Choose email, feed, github or a built-in watcher.")
    every = config.get("every_minutes", 5)
    if isinstance(every, bool) or not isinstance(every, int) or not 1 <= every <= 1440:
        raise SourceError("Poll every 1–1440 minutes.")
    if source == "feed":
        url = urlsplit(config.get("url", ""))
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
            raise SourceError("Use a public HTTPS RSS/JSON feed.")
    if source == "github" and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", config.get("repo", "")):
        raise SourceError("Use a GitHub owner/repo.")
    if source == "builtin" and config.get("kind") not in ("leave_now", "birthday", "follow_up"):
        raise SourceError("Unknown built-in watcher.")
    if source == "email" and (not isinstance(config.get("query", "is:unread"), str) or len(config.get("query", "")) > 1000):
        raise SourceError("Invalid Gmail search query.")
    return config


def allowed_url(source, config, target):
    url = urlsplit(target)
    if source == "feed":
        grant = urlsplit(config["url"])
        valid = (url.scheme, url.hostname, url.port, url.path) == (grant.scheme, grant.hostname, grant.port, grant.path)
    elif source == "github":
        prefix = "/repos/" + config["repo"] + "/"
        normalized = posixpath.normpath(unquote(url.path))
        valid = url.scheme == "https" and url.hostname == "api.github.com" and url.port in (None, 443) and normalized.startswith(prefix) and normalized == url.path
    else:
        valid = False
    if not valid or url.username or url.password or url.fragment:
        raise SourceError("HTTP is limited to this watcher's read-only source API.")
    return url


class PinnedHTTPS(http.client.HTTPSConnection):
    def connect(self):
        addresses = socket.getaddrinfo(self.host, self.port, type=socket.SOCK_STREAM)
        if not addresses or any(not ipaddress.ip_address(row[4][0]).is_global for row in addresses):
            raise SourceError("Source address must be public; private/loopback destinations are denied.")
        self.sock = socket.create_connection(addresses[0][4][:2], self.timeout)
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.host)


def http_get(source, config, target):
    url = allowed_url(source, config, target)
    connection = PinnedHTTPS(url.hostname, url.port, timeout=10, context=ssl.create_default_context())
    try:
        headers = {"User-Agent": "Alice-Watcher/1", "Accept": "application/json, application/atom+xml, application/rss+xml"}
        if source == "github" and os.environ.get("GITHUB_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
        connection.request("GET", url.path + ("?" + url.query if url.query else ""), headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            raise SourceError("Source request failed (redirects are refused).")
        body = response.read(1048577)
        if len(body) > 1048576:
            raise SourceError("Source exceeds 1 MB.")
        return body.decode("utf-8")
    finally:
        connection.close()


def parse_feed(text):
    if text.lstrip().startswith(("{", "[")):
        value = json.loads(text)
        items = value.get("items", []) if isinstance(value, dict) else value
        if not isinstance(items, list):
            raise SourceError("JSON feed items must be a list.")
        return [{**item, "body": item.get("body", item.get("content_text", item.get("content_html"))),
                 "subject": item.get("subject", item.get("title", ""))} for item in items[:200] if isinstance(item, dict)]
    if "<!DOCTYPE" in text.upper() or "<!ENTITY" in text.upper():
        raise SourceError("XML entities are not supported.")
    root = ET.fromstring(text)
    rows = root.findall(".//item") or root.findall("{http://www.w3.org/2005/Atom}entry")
    def field(row, names):
        for name in names:
            element = row.find(name)
            if element is not None:
                return "".join(element.itertext())
        return ""
    ns = "{http://www.w3.org/2005/Atom}"
    items = []
    for row in rows[:200]:
        subject = field(row, ("title", ns + "title"))
        body = field(row, ("description", ns + "content", ns + "summary"))
        identity = field(row, ("guid", "link", ns + "id")) or hashlib.sha256((subject + body).encode()).hexdigest()
        items.append({"id": identity, "subject": subject, "body": body})
    return items


class Sources:
    def __init__(self, home, get=http_get, command=subprocess.run):
        self.home, self.get, self.command = Path(home), get, command

    def gmail(self, args):
        script = self.home / "hermes-agent/skills/productivity/google-workspace/scripts/google_api.py"
        if not script.is_file():
            raise SourceError("Connect Gmail using Hermes' Google Workspace skill before activating an email watcher.")
        out = self.command([sys.executable, str(script), "gmail", *args], capture_output=True, text=True, timeout=20)
        if out.returncode or len(out.stdout.encode()) > 1048576:
            raise SourceError("Gmail source failed; no classifier was called.")
        return json.loads(out.stdout)

    def items(self, watcher, now):
        source, config = watcher["source"], watcher["config"]
        if source == "feed":
            return parse_feed(self.get(source, config, config["url"]))
        if source == "github":
            url = "https://api.github.com/repos/" + config["repo"] + "/issues?" + urlencode({"state": "all", "sort": "updated", "direction": "desc", "per_page": 100})
            rows = json.loads(self.get(source, config, url))
            return [{"id": str(row["id"]) + ":" + row["updated_at"], "subject": row["title"],
                     "body": row.get("body") or "", "sender": row.get("user", {}).get("login", ""), "url": row.get("html_url", "")}
                    for row in rows if isinstance(row, dict)]
        if source == "email":
            items = []
            for row in self.gmail(["search", config.get("query", "is:unread"), "--max", "20"]):
                try:
                    full = self.gmail(["get", str(row["id"])])
                    items.append({**full, "sender": full.get("from", "")})
                except Exception:
                    items.append({**row, "source_error": "missing_body"})
            return items
        if source == "builtin":
            # Import only trusted sibling code, not a path supplied in config or an event.
            import importlib.util
            spec = importlib.util.spec_from_file_location("alice_watcher_builtins", Path(__file__).with_name("watcher_builtins.py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module.items(self.home, config, now)
        raise SourceError("Unknown source.")
