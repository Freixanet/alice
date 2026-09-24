"""What each agent did that changed something, in one record Alice can show.

Hermes keeps every tool call inside each profile's sessions, but nothing answers "what
have my agents done today": sent, scheduled, signed in, saved, deleted. A ``post_tool_call``
hook classifies each finished call and appends the ones with consequences to
``<hermes root>/.alice/actions.jsonl``; the dashboard serves them to the iPhone, which
shows them in Activity with a link back to the chat or routine where each happened.

What is kept is the kind of action and what it touched — a recipient, a routine's name, a
file's path, a website's address — never a message body, a command line, a password or a
memory's text. Reading is not an action: searches, page reads, file reads and listings are
never recorded.

The same module answers the iPhone's receipts: a few turns of a past conversation around
the message an agent cited, read from that profile's ``state.db``.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

LOG = Path(".alice") / "actions.jsonl"
# Bounded: a phone shows the recent weeks, and the file must not grow forever.
MAX_BYTES = 1_000_000
KEEP_LINES = 2000
TARGET_CHARS = 120
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

# ── Classification ───────────────────────────────────────────────────────────────


def _clip(value: Any) -> str:
    text = " ".join(str(value or "").split())
    return text if len(text) <= TARGET_CHARS else text[: TARGET_CHARS - 1] + "…"


def _home_path(raw: str) -> str:
    home = str(Path.home())
    return "~" + raw[len(home):] if raw.startswith(home) else raw


def _internal_path(raw: str, hermes_root: Optional[Path]) -> bool:
    """An agent's own workspace, caches and scratch space are its desk, not his files."""
    path = os.path.expanduser(str(raw or "").strip())
    if not path.startswith("/"):
        return True  # relative: the agent's working directory, which is its workspace
    scratch = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/")
    if path.startswith(scratch):
        return True
    if hermes_root is not None:
        root = str(hermes_root).rstrip("/") + "/"
        if path.startswith(root):
            return True
    return "/.cache/" in path or "/node_modules/" in path


def _parsed_result(result: Any) -> Dict[str, Any]:
    if isinstance(result, dict):
        return result
    try:
        parsed = json.loads(result) if isinstance(result, str) else None
    except (TypeError, ValueError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _words(command: str) -> List[str]:
    try:
        return shlex.split(command, posix=True)
    except ValueError:
        return command.split()


def _flag(words: List[str], *names: str) -> str:
    for index, word in enumerate(words):
        for name in names:
            if word == name and index + 1 < len(words):
                return words[index + 1]
            if word.startswith(name + "="):
                return word.split("=", 1)[1]
    return ""


_GOOGLE = re.compile(r"google_api\.py\s+(gmail|calendar|drive|docs|sheets)\s+([a-z_-]+)")
_INSTALL = re.compile(r"\b(?:pip3?|uv pip|npm|pnpm|yarn|brew|gem|cargo|pipx)\s+(?:install|add)\b")
_HOST = re.compile(r"https?://([^/\s'\"]+)")

_ROUTINE_ACTIONS = {
    "create": "routine.created", "add": "routine.created",
    "update": "routine.changed", "edit": "routine.changed",
    "remove": "routine.removed", "delete": "routine.removed",
    "pause": "routine.paused", "resume": "routine.resumed",
    "run": "routine.ran", "trigger": "routine.ran",
}


def _terminal(command: str, hermes_root: Optional[Path]) -> Optional[Dict[str, str]]:
    """The few shell commands whose effect a person would want on record."""
    if not command:
        return None
    for part in re.split(r"\s*(?:&&|\|\||;|\n)\s*", command):
        words = _words(part)
        if not words:
            continue
        google = _GOOGLE.search(part)
        if google:
            service, verb = google.groups()
            if service == "gmail" and verb == "send":
                return {"kind": "email.sent", "target": _flag(words, "--to")}
            if service == "gmail" and verb in ("draft", "create-draft", "drafts"):
                return {"kind": "email.drafted", "target": _flag(words, "--to")}
            if service == "gmail" and verb == "reply":
                return {"kind": "email.sent", "target": _flag(words, "--to")}
            if service == "calendar" and verb in ("create", "add", "insert", "quick-add"):
                return {"kind": "calendar.created", "target": _flag(words, "--summary", "--title")}
            if service == "calendar" and verb in ("update", "patch", "move"):
                return {"kind": "calendar.changed", "target": _flag(words, "--summary", "--title")}
            if service == "calendar" and verb in ("delete", "remove", "cancel"):
                return {"kind": "calendar.removed", "target": _flag(words, "--summary", "--title")}
            continue
        head = os.path.basename(words[0])
        if head == "git" and "push" in words[1:3]:
            rest = [w for w in words[words.index("push") + 1:] if not w.startswith("-")]
            return {"kind": "code.pushed", "target": " ".join(rest[:2])}
        if head in ("rm", "trash", "srm"):
            paths = [w for w in words[1:] if not w.startswith("-")]
            outside = [p for p in paths if not _internal_path(p, hermes_root)]
            if outside:
                names = ", ".join(_home_path(os.path.expanduser(p)) for p in outside[:2])
                more = f" +{len(outside) - 2}" if len(outside) > 2 else ""
                return {"kind": "file.deleted", "target": names + more}
            continue
        if _INSTALL.search(part):
            packages = [w for w in words[2:] if not w.startswith("-") and w not in ("install", "add", "pip")]
            return {"kind": "package.installed", "target": ", ".join(packages[:3])}
        if head == "osascript" and "Messages" in part and "send" in part:
            return {"kind": "message.sent", "target": "iMessage"}
        if head == "hermes" and len(words) > 2 and words[1] == "cron" and words[2] in _ROUTINE_ACTIONS:
            name = _flag(words, "--name") or (words[3] if len(words) > 3 and not words[3].startswith("-") else "")
            return {"kind": _ROUTINE_ACTIONS[words[2]], "target": name}
        if head == "hermes" and words[1:3] == ["config", "set"] and len(words) > 3:
            return {"kind": "settings.changed", "target": words[3]}
        if head == "curl" and (
            _flag(words, "-X", "--request").upper() in ("POST", "PUT", "PATCH", "DELETE")
            or any(w in ("-d", "--data", "--data-raw", "--json", "-F", "--form") or w.startswith("--data") for w in words)
        ):
            host = _HOST.search(part)
            if host and not host.group(1).startswith(("localhost", "127.0.0.1", "[::1]")):
                return {"kind": "web.sent", "target": host.group(1)}
    return None


_MCP_VERBS = ("send", "create", "delete", "remove", "update", "post", "publish", "book", "buy", "pay",
              "transfer", "cancel", "reply", "invite", "share", "upload")


def classify(tool: str, args: Optional[Dict[str, Any]], result: Any = None,
             hermes_root: Optional[Path] = None) -> Optional[Dict[str, str]]:
    """``{"kind", "target"}`` for a call with consequences, else None."""
    tool = str(tool or "")
    args = args if isinstance(args, dict) else {}
    action = str(args.get("action") or "").strip().lower()

    if tool == "send_message":
        if action in ("", "send"):
            return {"kind": "message.sent", "target": args.get("target")}
        return None
    if tool == "message_agent":
        return {"kind": "agent.messaged", "target": args.get("target")}
    if tool in ("cronjob", "cronjob_manage"):
        kind = _ROUTINE_ACTIONS.get(action)
        return {"kind": kind, "target": args.get("name") or args.get("job_id")} if kind else None
    if tool == "memory":
        kind = {"add": "memory.saved", "replace": "memory.updated", "remove": "memory.forgot"}.get(action)
        return {"kind": kind, "target": args.get("target")} if kind else None
    if tool == "skill_manage":
        operations = args.get("operations") if isinstance(args.get("operations"), list) else [args]
        actions = {str((op or {}).get("action") or "").lower() for op in operations if isinstance(op, dict)}
        names = [str(op.get("name")) for op in operations if isinstance(op, dict) and op.get("name")]
        if actions & {"delete", "remove"}:
            kind = "skill.removed"
        elif "create" in actions:
            kind = "skill.created"
        elif actions & {"edit", "patch", "write_file", "update", "remove_file"}:
            kind = "skill.changed"
        else:
            return None
        return {"kind": kind, "target": ", ".join(dict.fromkeys(names))}
    if tool in ("write_file", "patch"):
        path = args.get("path") or args.get("file_path") or ""
        if _internal_path(path, hermes_root):
            return None
        return {"kind": "file.written", "target": _home_path(os.path.expanduser(str(path)))}
    if tool == "ha_call_service":
        entity = args.get("entity_id")
        service = ".".join(str(x) for x in (args.get("domain"), args.get("service")) if x)
        return {"kind": "home.controlled", "target": f"{service} {entity}".strip() if entity else service}
    if tool == "browser_vault_fill":
        origin = _parsed_result(result).get("origin") or ""
        return {"kind": "login.used", "target": re.sub(r"^https?://", "", str(origin))}
    if tool == "browser_vault_save_login":
        return {"kind": "login.saved", "target": args.get("label")}
    if tool == "agent_create":
        return {"kind": "agent.created", "target": args.get("name") or args.get("display_name")}
    if tool == "agent_rename":
        return {"kind": "agent.renamed", "target": args.get("new_name") or args.get("name")}
    if tool == "note_add":
        return {"kind": "note.saved", "target": ""}
    if tool == "manage_connections" and action in ("connect", "add", "enable", "disconnect", "remove", "disable"):
        connectors = args.get("connectors") if isinstance(args.get("connectors"), list) else []
        return {"kind": "connector.changed", "target": ", ".join(str(c) for c in connectors[:3])}
    if tool in ("terminal", "execute_code"):
        return _terminal(str(args.get("command") or args.get("code") or ""), hermes_root)
    if tool.startswith("mcp_"):
        name = tool.split("__")[-1] if "__" in tool else tool[4:]
        lowered = name.lower()
        if ("mail" in lowered or "gmail" in tool.lower()) and ("send" in lowered or "reply" in lowered):
            return {"kind": "email.sent", "target": args.get("to") or args.get("recipient")}
        if any(verb in lowered.split("_") for verb in _MCP_VERBS):
            return {"kind": "external.acted", "target": name.replace("_", " ")}
    return None


# ── Recording ────────────────────────────────────────────────────────────────────


def _log_path(root: Path) -> Path:
    return Path(root) / LOG


def record(root: Path, *, profile: str, session: str, tool: str, kind: str, target: Any,
           ok: bool, now: Optional[float] = None) -> Dict[str, Any]:
    entry = {"v": 1, "id": uuid.uuid4().hex[:16], "at": round(now or time.time(), 3),
             "profile": profile or "default", "session": session or "", "tool": tool,
             "kind": kind, "target": _clip(target), "ok": bool(ok)}
    path = _log_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(entry, ensure_ascii=False) + "\n"
    # One short line in append mode: whole even with two gateways writing at once.
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(line)
    try:
        if path.stat().st_size > MAX_BYTES:
            _trim(path)
    except OSError:
        pass
    return entry


def _trim(path: Path) -> None:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    temp = path.with_suffix(".tmp")
    temp.write_text("".join(lines[-KEEP_LINES:]), encoding="utf-8")
    os.replace(temp, path)


def observe(root: Path, profile: str, *, tool_name: str, args: Any, result: Any, session_id: str = "",
            status: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """The hook's whole job: classify, and keep the call if it had consequences."""
    found = classify(tool_name, args if isinstance(args, dict) else {}, result, root)
    if not found or not found.get("kind"):
        return None
    # Hermes refusing its own background curator (a bundled or user-made skill)
    # is a protection working, not something an agent did.
    if status == "error" and "Refusing background curator" in str(result or ""):
        return None
    return record(root, profile=profile, session=session_id, tool=tool_name, kind=found["kind"],
                  target=found.get("target"), ok=status != "error")


# ── Reading ──────────────────────────────────────────────────────────────────────


def _profile_db(root: Path, profile: str) -> Optional[Path]:
    if profile in ("", "default"):
        path = Path(root) / "state.db"
    elif PROFILE_RE.match(profile):
        path = Path(root) / "profiles" / profile / "state.db"
    else:
        return None
    return path if path.is_file() else None


def _connect(db: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    return connection


def _session_rows(root: Path, profile: str, ids: Iterable[str]) -> Dict[str, Dict[str, Any]]:
    ids = [i for i in dict.fromkeys(ids) if i]
    db = _profile_db(root, profile)
    if not ids or db is None:
        return {}
    try:
        with _connect(db) as connection:
            marks = ",".join("?" * len(ids))
            rows = connection.execute(
                f"SELECT id, source, title, started_at FROM sessions WHERE id IN ({marks})", ids).fetchall()
    except sqlite3.Error:
        return {}
    return {row["id"]: dict(row) for row in rows}


def origin(profile: str, session: str, row: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Where an action happened, in the terms the iPhone opens: a routine or a chat."""
    source = (row or {}).get("source") or ""
    title = (row or {}).get("title") or ""
    match = re.match(r"^cron_([0-9a-f]{6,})_", session or "")
    if source == "cron" or match:
        name = title.split(" · ")[0].strip() if title else ""
        return {"place": "routine", "title": name, "routine": f"{profile}/{match.group(1)}" if match else None}
    return {"place": "chat", "title": title}


def recent(root: Path, *, limit: int = 200, since: Optional[float] = None,
           profile: Optional[str] = None) -> List[Dict[str, Any]]:
    path = _log_path(root)
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    entries: List[Dict[str, Any]] = []
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict) or not entry.get("kind"):
            continue
        if since is not None and float(entry.get("at") or 0) <= since:
            break
        if profile and entry.get("profile") != profile:
            continue
        entries.append(entry)
        if len(entries) >= limit:
            break
    by_profile: Dict[str, List[str]] = {}
    for entry in entries:
        by_profile.setdefault(entry.get("profile") or "default", []).append(entry.get("session") or "")
    sessions = {name: _session_rows(root, name, ids) for name, ids in by_profile.items()}
    for entry in entries:
        name = entry.get("profile") or "default"
        entry["origin"] = origin(name, entry.get("session") or "", sessions.get(name, {}).get(entry.get("session")))
    return entries


# ── Receipts ─────────────────────────────────────────────────────────────────────

RECEIPT_CHARS = 700
_FENCE = re.compile(r"```alice-ui.*?(```|$)", re.S)


def _readable(text: str) -> str:
    text = _FENCE.sub("", text or "").strip()
    return text if len(text) <= RECEIPT_CHARS else text[: RECEIPT_CHARS - 1].rstrip() + "…"


def receipt(root: Path, profile: str, session: str, around: Optional[int] = None,
            window: int = 3, at: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """A few spoken turns of a past conversation around ``around`` — a cited message — or
    around the moment ``at`` an action happened, or else its last few."""
    db = _profile_db(root, profile or "default")
    if db is None or not session:
        return None
    window = max(1, min(int(window), 6))
    spoken = "role IN ('user','assistant') AND coalesce(trim(content),'') != ''"
    try:
        with _connect(db) as connection:
            row = connection.execute(
                "SELECT id, source, title, started_at FROM sessions WHERE id = ?", (session,)).fetchone()
            if row is None:
                return None
            if around is None and at is not None:
                moment = connection.execute(
                    f"SELECT id FROM messages WHERE session_id = ? AND timestamp <= ? AND {spoken} "
                    "ORDER BY id DESC LIMIT 1", (session, at)).fetchone()
                around = moment["id"] if moment else None
            if around is not None:
                owner = connection.execute("SELECT session_id FROM messages WHERE id = ?", (around,)).fetchone()
                if owner is None or owner["session_id"] != session:
                    around = None
            if around is not None:
                before = connection.execute(
                    f"SELECT id, role, content, timestamp FROM messages WHERE session_id = ? AND id <= ? AND {spoken} "
                    "ORDER BY id DESC LIMIT ?", (session, around, window + 1)).fetchall()
                after = connection.execute(
                    f"SELECT id, role, content, timestamp FROM messages WHERE session_id = ? AND id > ? AND {spoken} "
                    "ORDER BY id ASC LIMIT ?", (session, around, window)).fetchall()
                rows = list(reversed(before)) + list(after)
            else:
                rows = list(reversed(connection.execute(
                    f"SELECT id, role, content, timestamp FROM messages WHERE session_id = ? AND {spoken} "
                    "ORDER BY id DESC LIMIT ?", (session, window * 2)).fetchall()))
    except sqlite3.Error:
        return None
    # The cited turn is the anchor, or the nearest spoken turn before it.
    anchor = None
    if around is not None:
        anchor = max((r["id"] for r in rows if r["id"] <= around), default=None)
    messages = [{"id": str(r["id"]), "role": r["role"], "text": _readable(r["content"]),
                 "at": r["timestamp"], "anchor": r["id"] == anchor} for r in rows]
    return {"profile": profile or "default", "session": session, "title": row["title"] or "",
            "started_at": row["started_at"], "origin": origin(profile or "default", session, dict(row)),
            "messages": [m for m in messages if m["text"]]}
