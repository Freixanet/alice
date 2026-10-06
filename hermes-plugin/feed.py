"""The editorial feed: posts Alice writes fresh for the person, cited with what research found.

Not an aggregator. Each run is one agent turn in Alice's own profile (her memory, her tools,
the person's connected services) on the gateway's ``/v1/runs``, driven from outside the
agent the way errands are. It reads the person's brief, the recent posts (so nothing is
repeated) and what the person did with them (love, discuss, delete), researches, and
publishes up to six posts through ``feed_publish``.

Provenance is closed in code, not only in the prompt: while a feed run researches, every URL
its web and browser tools return is registered and the result the agent reads is annotated
with a stable ``[alice_source: src_N]`` id. ``feed_publish`` accepts those ids only and
resolves them itself, so a post can cite nothing research did not surface.

Two processes touch this module. The agent process (hooks and tools) keeps the per-run
source registry in memory and publishes. The worker (a detached process started from the
dashboard or the schedule, one at a time by file lock) queues, drives and settles runs.

    python feed.py work <hermes_home>   # the worker, normally started by ``kick``
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

logger = logging.getLogger("alice.feed")

SCHEMA_VERSION = 1
SESSION_PREFIX = "feed-"
MAX_POSTS_PER_RUN = 6
KEEP_POSTS = 200
MAX_STEERING = 20
RUN_TIMEOUT = 20 * 60
POLL_SECONDS = 5
DEFAULT_TIMES = ["08:00", "19:00"]
JOB_NAME = "Alice · Feed"
JOB_SCRIPT = "alice-feed.py"
EVENT_KINDS = ("love", "discuss", "delete")
FINISHED = ("completed", "failed", "cancelled", "interrupted")
LIVE = ("running", "waiting_for_approval", "queued")
# Tools whose results can carry sources worth citing.
SOURCE_TOOLS = ("web_search", "web_extract", "browser_")
TRACKING = re.compile(r"^(utm_.*|fbclid|gclid|mc_.*|ref|ref_src|igshid)$", re.I)
URL_RE = re.compile(r"https?://[^\s\"'<>()\[\]{}\\]+", re.I)
MARKER = re.compile(r"\[(\d{1,2})\]")


class FeedError(ValueError):
    """A request the feed refuses; the message says why, for the agent or the app."""


# ── Store ───────────────────────────────────────────────────────────────────────


def _path(home: Path) -> Path:
    return Path(home) / ".alice" / "feed.json"


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


def _zone() -> str:
    try:
        from hermes_time import get_timezone

        zone = get_timezone()
        name = getattr(zone, "key", None) or str(zone)
        if name:
            return name
    except Exception:
        pass
    try:
        return str(Path("/etc/localtime").resolve()).split("zoneinfo/")[1]
    except (OSError, IndexError):
        return "UTC"


def _empty() -> Dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION, "revision": 0, "posts": [], "events": [], "steering": [],
        "brief": {"text": "", "updatedAt": None},
        "generation": _idle_generation(),
        "schedule": {"times": list(DEFAULT_TIMES), "timeZone": _zone()},
    }


def _idle_generation() -> Dict[str, Any]:
    return {"state": "idle", "requestedAt": None, "startedAt": None, "finishedAt": None, "reason": "",
            "reasons": [], "error": "", "sessionID": "", "runToken": "", "runId": "", "published": False,
            "publishedCount": 0, "pendingAfterRun": False, "pendingReasons": [], "pendingRequestedAt": None}


def _read(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    base = _empty()
    base.update({k: v for k, v in data.items() if k in base})
    generation = _idle_generation()
    generation.update(data.get("generation") or {})
    base["generation"] = generation
    return base


def _write(path: Path, data: Dict[str, Any]) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(Path(path).parent), prefix=".feed.")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _mutate(home: Path, change: Callable[[Dict[str, Any]], Any]) -> Any:
    """Runs ``change`` on the store under the lock; a change that returns without raising is saved,
    and every saved change bumps ``revision`` so a phone can tell something moved."""
    with _locked(home) as path:
        data = _read(path)
        result = change(data)
        data["revision"] = int(data.get("revision") or 0) + 1
        _write(path, data)
        return result


def load(home: Path) -> Dict[str, Any]:
    with _locked(home) as path:
        return _read(path)


# ── URLs and the per-run source registry (agent process) ────────────────────────


def normalize_url(url: str) -> str:
    """One key for the same page however it was linked: https, lowercased host without ``www.``,
    no fragment, no tracking parameters, the rest of the query sorted, no trailing slash."""
    try:
        parts = urlsplit(str(url or "").strip())
    except ValueError:
        return ""
    if parts.scheme.lower() not in ("http", "https") or not parts.netloc:
        return ""
    host = parts.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    query = sorted((k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if not TRACKING.match(k))
    path = parts.path.rstrip("/")
    return urlunsplit(("https", host, path, urlencode(query), ""))


class Registry:
    """What one feed run's research surfaced: ``src_N`` → the URL exactly as it came, and a title."""

    def __init__(self) -> None:
        self.sources: Dict[str, Dict[str, str]] = {}
        self._by_key: Dict[str, str] = {}

    def add(self, url: str, title: str = "") -> Optional[str]:
        url = str(url or "").strip().rstrip(".,;:")
        key = normalize_url(url)
        if not key:
            return None
        if key in self._by_key:
            ref = self._by_key[key]
            if title and not self.sources[ref].get("title"):
                self.sources[ref]["title"] = title[:200]
            return ref
        ref = f"src_{len(self.sources) + 1:02d}"
        self.sources[ref] = {"url": url, "title": (title or "")[:200]}
        self._by_key[key] = ref
        return ref


_registries: Dict[str, Registry] = {}
_registries_lock = threading.Lock()


def registry_for(session_id: str) -> Registry:
    with _registries_lock:
        # Only the run under way keeps one: an ended run's sources are already in its posts.
        for other in [s for s in _registries if s != session_id]:
            _registries.pop(other, None)
        return _registries.setdefault(session_id, Registry())


def drop_registry(session_id: str) -> None:
    with _registries_lock:
        _registries.pop(session_id, None)


def _found(result: str) -> List[Tuple[str, str]]:
    """(url, title) pairs in a tool result: from JSON items when it is JSON, else every URL."""
    pairs: List[Tuple[str, str]] = []

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            url = node.get("url") or node.get("link") or node.get("href")
            if isinstance(url, str) and url.startswith("http"):
                pairs.append((url, str(node.get("title") or node.get("name") or "")))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    try:
        walk(json.loads(result))
    except (TypeError, ValueError):
        pass
    known = {normalize_url(u) for u, _ in pairs}
    for url in URL_RE.findall(result or ""):
        if normalize_url(url) not in known:
            pairs.append((url, ""))
            known.add(normalize_url(url))
    return pairs


def is_feed_session(session_id: str) -> bool:
    return str(session_id or "").startswith(SESSION_PREFIX)


def annotate(session_id: str, tool_name: str, result: Any) -> Optional[str]:
    """The tool result the agent reads, with each source it carries named ``[alice_source: src_N]``.
    None when there is nothing to add (not a feed run, not a source tool, no URL)."""
    if not is_feed_session(session_id) or not isinstance(result, str):
        return None
    name = str(tool_name or "")
    if not any(name == t or (t.endswith("_") and name.startswith(t)) for t in SOURCE_TOOLS):
        return None
    registry = registry_for(session_id)
    lines = []
    for url, title in _found(result):
        ref = registry.add(url, title)
        if ref:
            lines.append(f"[alice_source: {ref}] {title or '(no title)'} — {url}")
    if not lines:
        return None
    return (result + "\n\nSources you may cite in feed_publish (by id only):\n" + "\n".join(dict.fromkeys(lines)))


# ── Generation requests ─────────────────────────────────────────────────────────


def request(home: Path, reason: str, now: Optional[float] = None) -> Dict[str, Any]:
    """Asks for a generation. One at a time: queued adds its reason; running leaves exactly one
    run pending for afterwards, however many times it is asked."""
    now = now or time.time()

    def change(data: Dict[str, Any]) -> Dict[str, Any]:
        gen = data["generation"]
        if gen["state"] == "queued":
            gen["reasons"] = list(dict.fromkeys((gen.get("reasons") or []) + [reason]))
            return {"queued": True, "state": "queued", "pending": False}
        if gen["state"] == "running":
            gen["pendingAfterRun"] = True
            gen["pendingReasons"] = list(dict.fromkeys((gen.get("pendingReasons") or []) + [reason]))
            gen["pendingRequestedAt"] = gen.get("pendingRequestedAt") or now
            return {"queued": True, "state": "running", "pending": True}
        fresh = _idle_generation()
        fresh.update(state="queued", requestedAt=now, reason=reason, reasons=[reason], runToken=uuid.uuid4().hex)
        data["generation"] = fresh
        return {"queued": True, "state": "queued", "pending": False}

    return _mutate(home, change)


def set_brief(home: Path, text: str, now: Optional[float] = None) -> Dict[str, Any]:
    text = str(text or "").strip()[:4000]
    now = now or time.time()

    def change(data: Dict[str, Any]) -> bool:
        if (data["brief"].get("text") or "") == text:
            return False
        data["brief"] = {"text": text, "updatedAt": now}
        return True

    changed = _mutate(home, change)
    if not changed:
        return {"changed": False, "queued": False}
    outcome = request(home, "brief", now)
    return {"changed": True, **outcome,
            "note": "The new brief applies to the next run." if outcome.get("pending") else ""}


def add_steering(home: Path, note: str, now: Optional[float] = None) -> Dict[str, Any]:
    note = " ".join(str(note or "").split())[:300]
    if not note:
        raise FeedError("Say what to change, in a few words.")
    now = now or time.time()

    def change(data: Dict[str, Any]) -> int:
        data["steering"] = ((data.get("steering") or []) + [{"note": note, "at": now}])[-MAX_STEERING:]
        return len(data["steering"])

    return {"saved": True, "notes": _mutate(home, change), "applies": "from the next feed run"}


# ── Events: what the person did with a post ─────────────────────────────────────


def add_event(home: Path, post_id: str, event: Dict[str, Any], now: Optional[float] = None) -> Dict[str, Any]:
    """One love / discuss / delete, idempotent by its UUID. Raises FeedError (400) for a bad
    event and LookupError (410) for a post no longer kept."""
    event_id = str(event.get("id") or "").strip()
    kind = str(event.get("kind") or "")
    try:
        uuid.UUID(event_id)
    except ValueError as exc:
        raise FeedError("The event needs a UUID id.") from exc
    if kind not in EVENT_KINDS:
        raise FeedError("kind must be love, discuss or delete.")
    has_on = "on" in event and event.get("on") is not None
    if kind in ("love", "delete") and (not has_on or not isinstance(event.get("on"), bool)):
        raise FeedError(f"A {kind} event needs on: true or false.")
    if kind == "discuss" and has_on:
        raise FeedError("A discuss event takes no on.")
    created = event.get("createdAt")
    created = float(created) if isinstance(created, (int, float)) else (now or time.time())

    def change(data: Dict[str, Any]) -> Dict[str, Any]:
        if any(e.get("id") == event_id for e in data["events"]):
            return {"applied": False, "duplicate": True}
        if not any(p.get("id") == post_id for p in data["posts"]):
            raise LookupError(post_id)
        row = {"id": event_id, "postId": post_id, "kind": kind, "createdAt": created}
        if kind != "discuss":
            row["on"] = bool(event["on"])
        data["events"].append(row)
        return {"applied": True, "duplicate": False}

    with _locked(home) as path:
        data = _read(path)
        result = change(data)
        if result.get("applied"):
            data["revision"] = int(data.get("revision") or 0) + 1
            _write(path, data)
        return result


def viewer_states(events: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """Per post, from its events in order: loved and deleted are the last word; discussions count."""
    states: Dict[str, Dict[str, Any]] = {}
    for event in sorted(events, key=lambda e: float(e.get("createdAt") or 0)):
        state = states.setdefault(event.get("postId", ""), {"loved": False, "lovedAt": None,
                                                            "discussCount": 0, "deleted": False})
        if event.get("kind") == "love":
            state["loved"] = bool(event.get("on"))
            state["lovedAt"] = event.get("createdAt") if state["loved"] else None
        elif event.get("kind") == "delete":
            state["deleted"] = bool(event.get("on"))
        elif event.get("kind") == "discuss":
            state["discussCount"] += 1
    return states


# ── What the phone reads ────────────────────────────────────────────────────────


def _public_generation(gen: Dict[str, Any]) -> Dict[str, Any]:
    return {k: gen.get(k) for k in ("state", "requestedAt", "startedAt", "finishedAt", "error",
                                     "publishedCount", "pendingAfterRun")}


def status(home: Path) -> Dict[str, Any]:
    data = load(home)
    return {"revision": data["revision"], "generation": _public_generation(data["generation"])}


def listing(home: Path) -> Dict[str, Any]:
    data = load(home)
    states = viewer_states(data["events"])
    posts = []
    for post in data["posts"]:
        state = states.get(post["id"], {"loved": False, "lovedAt": None, "discussCount": 0, "deleted": False})
        if state["deleted"]:
            continue
        posts.append({**post, "viewerState": {k: state[k] for k in ("loved", "lovedAt", "discussCount")}})
    return {"revision": data["revision"], "posts": posts, "brief": data["brief"],
            "schedule": data["schedule"], "generation": _public_generation(data["generation"])}


# ── Publishing (agent process) ──────────────────────────────────────────────────


def _clean(value: Any, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit] if limit < 400 else str(value or "").strip()[:limit]


def _check_post(raw: Dict[str, Any], registry: Registry, index: int) -> Dict[str, Any]:
    where = f"Post {index + 1}"
    headline = _clean(raw.get("headline"), 160)
    body = _clean(raw.get("body"), 2400)
    if not headline or not body:
        raise FeedError(f"{where}: headline and body are required.")
    refs = [str(r).strip() for r in (raw.get("sources") or [])]
    if not refs:
        raise FeedError(f"{where}: cite at least one source.")
    sources = []
    for ref in refs:
        if URL_RE.match(ref):
            raise FeedError(f"{where}: cite sources by their [alice_source] id, never a raw URL ({ref[:60]}).")
        found = registry.sources.get(ref)
        if found is None:
            raise FeedError(f"{where}: {ref} is not a source your research surfaced in this run. "
                            "Cite only ids shown as [alice_source: src_N].")
        sources.append({"ref": ref, "title": found.get("title") or "", "url": found["url"]})
    if len({s["ref"] for s in sources}) != len(sources):
        raise FeedError(f"{where}: a source is listed twice.")
    markers = [int(m) for m in MARKER.findall(body)]
    if not markers:
        raise FeedError(f"{where}: cite each claim inline with [n], n being its position in sources.")
    bad = sorted({m for m in markers if not 1 <= m <= len(sources)})
    if bad:
        raise FeedError(f"{where}: markers {bad} do not match its {len(sources)} sources.")
    uncited = [i + 1 for i in range(len(sources)) if (i + 1) not in markers]
    if uncited:
        raise FeedError(f"{where}: sources {uncited} are listed but never cited in the body.")
    return {
        "kicker": _clean(raw.get("kicker"), 60), "category": _clean(raw.get("category"), 40),
        "headline": headline, "body": body, "sources": sources,
        "storyKey": re.sub(r"[^a-z0-9-]", "", _clean(raw.get("storyKey"), 80).lower()) or None,
        "whyThis": _clean(raw.get("whyThis"), 240) or None,
        "language": _clean(raw.get("language"), 12) or None,
    }


def publish(home: Path, session_id: str, posts: Any, registry: Optional[Registry] = None,
            now: Optional[float] = None) -> Dict[str, Any]:
    """``feed_publish``: only the active run's own session, once; 0–6 posts, all verified."""
    if not isinstance(posts, list):
        raise FeedError("posts must be a list (empty when nothing clears the bar).")
    if len(posts) > MAX_POSTS_PER_RUN:
        raise FeedError(f"At most {MAX_POSTS_PER_RUN} posts. Keep the best ones.")
    registry = registry or registry_for(session_id)
    checked = [_check_post(p if isinstance(p, dict) else {}, registry, i) for i, p in enumerate(posts)]
    now = now or time.time()

    def change(data: Dict[str, Any]) -> Dict[str, Any]:
        gen = data["generation"]
        if gen["state"] != "running" or not session_id or gen.get("sessionID") != session_id:
            raise FeedError("feed_publish only works inside the feed run under way.")
        if gen.get("published"):
            raise FeedError("This run has already published. Finish now.")
        stamped = [{"id": uuid.uuid4().hex[:16], "createdAt": now + i / 1000, **p}
                   for i, p in enumerate(reversed(checked))]
        data["posts"] = (list(reversed(stamped)) + data["posts"])[:KEEP_POSTS]
        gen["published"] = True
        gen["publishedCount"] = len(stamped)
        return {"published": len(stamped)}

    result = _mutate(home, change)
    logger.info("feed: run %s published %d posts", session_id, result["published"])
    return {"ok": True, **result, "next": "Done. Reply with one short line; nothing else to do."}


# ── The prompt ──────────────────────────────────────────────────────────────────

RULES = """You are writing Alice's editorial feed for the one person you serve. It is not an aggregator:
no RSS, no digests, no reposting, no ranking. Every post is authored fresh by you.

How to work:
1. Read the brief and taste notes below. Decide on a few distinct ideas worth this person's time today.
2. Research each with your tools: web search, reading pages, social platforms, and the person's
   connected services (mail, calendar, health) where the brief makes them relevant. Summarize what
   you learn from connected services; never quote or expose raw private data.
3. Research results are annotated with stable ids like [alice_source: src_07]. Those ids are the only
   way to cite. Invented URLs are forbidden; raw URLs are rejected. If a claim is not backed by a
   source you actually surfaced, do not write it. Never fabricate research.
4. Call feed_publish exactly once, at the end, with your posts — or with posts: [] when nothing
   clears the bar. A run that ends without calling feed_publish counts as failed.

Each post:
- One clear idea. Short and skimmable (a headline and 2–5 plain sentences). No hype, no clickbait.
- kicker: 1–4 words above the headline. category: one short topic word.
- Cite every factual claim inline with [n], n being the claim's source position in that post's
  sources list (sources: ["src_03", "src_07"] → [1] is src_03, [2] is src_07). Every listed source
  must be cited at least once.
- storyKey: a short slug for the story (e.g. apple-siri-model). Do not repeat a recent storyKey
  unless there is a material new development — then lead with what changed.
- whyThis (optional): one abstract sentence on why this is for them. Never reveal private data or
  its provenance in whyThis ("because your email said…"). Use abstract reasons ("You've shown
  repeated interest in AI agents") or omit whyThis for private or delicate inferences.
- language: write in the person's language (the brief's language; Spanish if unsure) and set it.

Up to 6 posts, quality before quantity: better 2 good posts than 5 of filler. Keep breadth — do not
let the feed collapse into 2–3 topics."""


def _ago(now: float, at: Any) -> float:
    try:
        return max(0.0, (now - float(at)) / 86400)
    except (TypeError, ValueError):
        return 999.0


def taste(data: Dict[str, Any], now: float) -> str:
    """What the person did with past posts, weighted toward the recent, with its meaning spelled out."""
    by_id = {p["id"]: p for p in data["posts"]}
    states = viewer_states(data["events"])
    loved, discussed, deleted = [], [], []
    weights: Dict[str, float] = {}
    for post_id, state in states.items():
        post = by_id.get(post_id)
        if not post:
            continue
        age = _ago(now, post.get("createdAt"))
        if age > 30:
            continue
        weight = 0.5 ** (age / 10)
        label = f"{post.get('headline')} ({post.get('category') or 'general'})"
        if state["loved"]:
            loved.append(label)
            weights[post.get("category") or "general"] = weights.get(post.get("category") or "general", 0) + 2 * weight
        if state["discussCount"]:
            discussed.append(f"{label} ×{state['discussCount']}")
            weights[post.get("category") or "general"] = (weights.get(post.get("category") or "general", 0)
                                                          + weight * min(3, state["discussCount"]))
        if state["deleted"]:
            deleted.append(label)
            weights[post.get("category") or "general"] = weights.get(post.get("category") or "general", 0) - 0.5 * weight
    lines = ["Taste signals (last 30 days, recent ones weigh more):",
             "Strong positive — loved, or discussed (more so when repeated). Weak negative — deleted:",
             "one deletion may mean already read, not now, or cleanup; never infer a permanent dislike from it."]
    for title, items in (("Loved", loved), ("Discussed", discussed), ("Deleted", deleted)):
        if items:
            lines.append(f"{title}: " + "; ".join(items[-12:]))
    if weights:
        ranked = sorted(weights.items(), key=lambda kv: -kv[1])
        lines.append("Net leaning by category: " + ", ".join(f"{k} {v:+.1f}" for k, v in ranked[:10]))
    if len(lines) == 3:
        lines.append("No signals yet.")
    return "\n".join(lines)


def prompt(home: Path, now: Optional[float] = None) -> str:
    now = now or time.time()
    data = load(home)
    brief = (data["brief"].get("text") or "").strip() or (
        "No brief yet. Choose broadly from what you know about the person; favour their stated "
        "interests and goals, and keep a mix.")
    recent = []
    seen = set()
    for post in data["posts"][:40]:
        key = post.get("headline")
        if key in seen:
            continue
        seen.add(key)
        recent.append(f"- [{post.get('category') or 'general'}] {post.get('headline')}")
    keys = sorted({p["storyKey"] for p in data["posts"] if p.get("storyKey") and _ago(now, p.get("createdAt")) <= 7})
    steering = [s.get("note") for s in reversed(data.get("steering") or []) if s.get("note")]
    parts = [RULES, "", "Brief from the person:", brief]
    if steering:
        parts += ["", "Steering the person gave since (newest first; applies now):"] + [f"- {s}" for s in steering]
    parts += ["", taste(data, now), "", "Recent posts (do not repeat their topic or angle):"]
    parts += recent or ["- none yet"]
    parts += ["", "Recent storyKeys (last 7 days): " + (", ".join(keys) if keys else "none")]
    return "\n".join(parts)


# ── The worker (its own process, one at a time) ─────────────────────────────────


def _sibling(name: str, file: str):
    import importlib.util

    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _worker_lock(home: Path):
    folder = Path(home) / ".alice"
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(folder / "feed-worker.lock", "w")  # noqa: SIM115 — held for the worker's life
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


class Worker:
    """Takes queued runs one after the other and settles each: published → idle (0 posts is a
    success), ended without publishing → failed, and a pending request becomes the next run."""

    def __init__(self, home: Path, *, gateway: Any = None, sleep: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.time):
        self.home = Path(home)
        self.gateway = gateway or _sibling("alice_errands", "errands.py").Gateway(self.home)
        self.sleep = sleep
        self.clock = clock

    def _set(self, **fields: Any) -> Dict[str, Any]:
        def change(data):
            data["generation"].update(fields)
            return dict(data["generation"])
        return _mutate(self.home, change)

    def _settle(self, error: str = "") -> None:
        """Ends the run under way and promotes a pending request to exactly one queued run."""
        def change(data):
            gen = data["generation"]
            # Published is success, whatever happened after it (0 posts included).
            ok = bool(gen.get("published"))
            outcome = {"state": "idle" if ok else "failed", "finishedAt": self.clock(),
                       "error": "" if ok else (error or "generation completed without publication")}
            gen.update(outcome)
            if gen.get("pendingAfterRun"):
                reasons = gen.get("pendingReasons") or ["pending"]
                fresh = _idle_generation()
                fresh.update(state="queued", requestedAt=gen.get("pendingRequestedAt") or self.clock(),
                             reason=reasons[0], reasons=reasons, runToken=uuid.uuid4().hex)
                data["generation"] = fresh
            return outcome
        outcome = _mutate(self.home, change)
        logger.info("feed: run settled as %s%s", outcome["state"],
                    f" ({outcome['error']})" if outcome["error"] else "")

    def _wait(self, run_id: str, started: float) -> str:
        """Polls the run to its end; '' when it finished, else why it failed."""
        while True:
            if self.clock() - started > RUN_TIMEOUT:
                try:
                    self.gateway.stop(run_id)
                except Exception:  # noqa: BLE001 — stopping is best effort; the run is over for us
                    pass
                return "timed out after 20 minutes"
            try:
                state = self.gateway.status(run_id)
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    return "the run disappeared from Hermes"
                raise
            status = str(state.get("status") or "")
            if status in FINISHED:
                if status == "completed":
                    return ""
                return _clean(state.get("error") or f"the run ended {status}", 200)
            self.sleep(POLL_SECONDS)

    def _recover(self, gen: Dict[str, Any]) -> None:
        """A run left ``running`` with no worker behind it (this lock was free): follow it if the
        gateway still has it, else settle it now."""
        run_id = gen.get("runId") or ""
        started = float(gen.get("startedAt") or 0)
        live = False
        if run_id and self.clock() - started < RUN_TIMEOUT:
            try:
                live = str(self.gateway.status(run_id).get("status") or "") in LIVE
            except Exception:  # noqa: BLE001 — unreachable or gone: nothing to follow
                live = False
        if live:
            logger.info("feed: resuming the live run %s", run_id)
            self._settle(self._wait(run_id, started))
        else:
            self._settle("" if gen.get("published") else "worker died or timed out")

    def run_once(self) -> bool:
        """Handles what the store says now; True when there may be more to do."""
        gen = load(self.home)["generation"]
        if gen["state"] == "running":
            self._recover(gen)
            return True
        if gen["state"] != "queued":
            return False
        started = self.clock()
        session = f"{SESSION_PREFIX}{int(started)}-{gen['runToken'][:6]}"
        self._set(state="running", startedAt=started, sessionID=session, runId="", published=False,
                  publishedCount=0, error="")
        logger.info("feed: run %s started (%s)", session, ", ".join(gen.get("reasons") or [gen.get("reason")]))
        try:
            # The gateway runs a session on an explicit model; the feed uses the errands' fixed one
            # (without it every run raised TypeError, reported as «could not reach Hermes»).
            route = _sibling("alice_errands", "errands.py").model_selection(self.home)
        except Exception as exc:  # noqa: BLE001
            self._settle(f"no model set for background runs: {exc}")
            return True
        try:
            run_id = self.gateway.start(session, prompt(self.home, started), **route)
        except (OSError, TimeoutError) as exc:
            self._settle(f"could not reach Hermes: {type(exc).__name__}")
            return True
        except Exception as exc:  # noqa: BLE001
            logger.exception("feed: run %s could not start", session)
            self._settle(f"the run could not start: {type(exc).__name__}")
            return True
        self._set(runId=run_id)
        try:
            error = self._wait(run_id, started)
        except Exception as exc:  # noqa: BLE001
            error = f"lost the run: {type(exc).__name__}"
        self._settle(error)
        return True

    def run(self) -> None:
        while self.run_once():
            pass


def work(home: Path) -> bool:
    """The worker's entry point: False when another worker already holds the lock."""
    lock = _worker_lock(home)
    if lock is None:
        return False
    try:
        Worker(home).run()
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()
    return True


def worker_alive(home: Path) -> bool:
    lock = _worker_lock(home)
    if lock is None:
        return True
    fcntl.flock(lock, fcntl.LOCK_UN)
    lock.close()
    return False


def kick(home: Path) -> bool:
    """Starts a detached worker when there is work and none is running. Safe to call often:
    it is also how a run orphaned by a crash gets settled or followed again."""
    gen = load(home)["generation"]
    if gen["state"] not in ("queued", "running") or worker_alive(home):
        return False
    log = Path(home) / "logs" / "alice-feed.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "a") as out:
        subprocess.Popen(  # noqa: S603 — our own module, our own interpreter
            [sys.executable, str(Path(__file__).resolve()), "work", str(Path(home))],
            stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True, close_fds=True)
    return True


# ── The schedule (a no_agent cron job that only queues) ─────────────────────────


def schedule_script(home: Path) -> str:
    return (
        "import importlib.util\n"
        f"spec = importlib.util.spec_from_file_location('alice_feed_cron', {str(Path(__file__).resolve())!r})\n"
        "module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)\n"
        f"module.request(module.Path({str(home)!r}), 'schedule')\n"
        f"module.kick(module.Path({str(home)!r}))\n"
    )


def cron_expression(times: List[str]) -> str:
    """08:00 and 19:00 → '0 8,19 * * *'; times sharing a minute share one expression."""
    parsed = []
    for value in times or DEFAULT_TIMES:
        match = re.fullmatch(r"(\d{1,2}):(\d{2})", str(value).strip())
        if match and int(match.group(1)) < 24 and int(match.group(2)) < 60:
            parsed.append((int(match.group(1)), int(match.group(2))))
    parsed = parsed or [(8, 0), (19, 0)]
    minute = parsed[0][1]
    hours = ",".join(str(h) for h, m in sorted(parsed) if m == minute)
    return f"{minute} {hours} * * *"


def ensure_schedule(home: Path, profile: str = "default", jobs: Any = None) -> Optional[str]:
    """One cron job for the feed, rebuilt when the stored schedule changes. Nothing is delivered.

    Cron is per profile: a job runs its script from its own profile's ``scripts`` folder. The feed
    is the person's, so only the main profile schedules it; any other profile's gateway removes the
    copy an earlier build left in its cron, whose script was never there («Script not found»)."""
    if jobs is None:
        try:
            import cron.jobs as jobs
        except Exception:
            return None
    ours = [j for j in jobs.load_jobs()
            if j.get("name") == JOB_NAME and str(j.get("script") or JOB_SCRIPT) == JOB_SCRIPT]
    if profile != "default":
        for job in ours:
            jobs.remove_job(job["id"])
        return None
    data = load(home)
    expression = cron_expression(data["schedule"].get("times") or DEFAULT_TIMES)
    scripts = Path(home) / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / JOB_SCRIPT).write_text(schedule_script(home), encoding="utf-8")
    keep = [j for j in ours if str((j.get("schedule") or {}).get("expr") or j.get("schedule_display") or "")
            .strip() == expression]
    for job in ours:
        if job not in keep[:1]:
            jobs.remove_job(job["id"])
    if keep:
        return keep[0]["id"]
    job = jobs.create_job(None, expression, name=JOB_NAME, deliver="local", script=JOB_SCRIPT, no_agent=True)
    return job.get("id")


# ── Tools ───────────────────────────────────────────────────────────────────────

PUBLISH_SCHEMA = {
    "name": "feed_publish",
    "description": ("Only inside a feed run: publish this run's posts, once, at the end. Cite sources by "
                    "their [alice_source: src_N] ids only. Pass posts: [] when nothing clears the bar."),
    "parameters": {
        "type": "object",
        "properties": {
            "posts": {
                "type": "array", "maxItems": MAX_POSTS_PER_RUN,
                "items": {
                    "type": "object",
                    "properties": {
                        "kicker": {"type": "string"}, "category": {"type": "string"},
                        "headline": {"type": "string"},
                        "body": {"type": "string", "description": "Markdown; every claim cited inline as [n]."},
                        "sources": {"type": "array", "items": {"type": "string"},
                                    "description": "Source ids in citation order, e.g. [\"src_03\", \"src_07\"]."},
                        "storyKey": {"type": "string"}, "whyThis": {"type": "string"},
                        "language": {"type": "string"},
                    },
                    "required": ["kicker", "category", "headline", "body", "sources", "language"],
                },
            },
        },
        "required": ["posts"],
    },
}

STEER_SCHEMA = {
    "name": "feed_steer",
    "description": ("Save what the person says about their feed (\"less crypto, more F1\"). It applies from "
                    "the next feed run. Use it whenever they steer the feed in chat."),
    "parameters": {"type": "object", "properties": {"note": {"type": "string"}}, "required": ["note"]},
}


def run_publish(home: Path, session_id: str, args: Dict[str, Any]) -> Dict[str, Any]:
    if not is_feed_session(session_id):
        return {"ok": False, "error": "feed_publish only works inside a feed run."}
    try:
        return publish(home, session_id, (args or {}).get("posts"))
    except FeedError as exc:
        return {"ok": False, "error": str(exc)}


def run_steer(home: Path, args: Dict[str, Any]) -> Dict[str, Any]:
    try:
        return {"ok": True, **add_steering(home, (args or {}).get("note"))}
    except FeedError as exc:
        return {"ok": False, "error": str(exc)}


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "work":
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
        sys.exit(0 if work(Path(sys.argv[2])) else 3)
    print(__doc__)
    sys.exit(2)
