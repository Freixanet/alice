"""Guard command egress even when the session's outside-content history is unavailable.

Meta's Muse keeps part of the trust decision below the model: once a process has read outside
content, its ability to send data out is held to tighter rules. Alice runs on the person's Mac
with their permissions, so this is the same idea at the tool layer, deterministic and cheap:

1. Outside-content reads taint a session before the first remote call is dispatched. A
   small, private SQLite ledger preserves that decision across plugin restarts; the
   in-memory observer remains useful for telemetry but is not a security authority.
2. Terminal/code commands therefore require approval in EVERY session unless they exactly
   match a very small list of local, read-only commands. Shell text cannot be classified
   securely by searching for HTTP verbs: GET, Git, subshells and interpreters all send data.
   Hermes shows the person the command on its approval card.
3. Once a session has read outside content, further web searches, remote URLs and browser
   actions require approval. A missing session ID or unreadable ledger blocks remote reads;
   the first read in a verified, unseen session is allowed.

This is a tool-level defense, not an OS sandbox. Unknown/unhooked tools, other processes and
browser network activity that does not go through a Hermes hook remain outside its boundary.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import threading
import time
from typing import Any, Dict, Optional

TAINT_TTL = 6 * 3600
# Tools that bring outside words into the conversation.
READS_OUTSIDE = re.compile(
    r"^(web_extract|web_search|browser_\w+|browser-use\w*|fetch\w*|read_email\w*|himalaya\w*|gmail\w*|"
    r"mcp_\w*(gmail|mail|web|browse|fetch|scrape)\w*)$", re.I)
# Tools whose arguments run code or commands.
RUNS_CODE = {"terminal", "execute_code", "shell", "bash", "run_command",
             "browser_exec", "python", "python_repl", "execute_python", "node",
             "javascript", "exec_command"}

# The URL, query or browser action itself can carry secrets, even if the HTTP
# method is GET and the secret is percent/base64 encoded. Classify by tool name,
# not by searching its arguments for suspicious-looking literals.
_REMOTE_TOOLS = re.compile(
    r"^(?:web_(?:search|extract|open|browse|fetch)|fetch\w*|http_(?:get|request|fetch)|"
    r"url_open|open_url|search_web|read_email\w*|gmail\w*|himalaya\w*|"
    r"browser_\w+|browser-use\w*|"
    r"mcp_\w*(?:gmail|mail|web|browse|browser|fetch|scrape|search)\w*)$", re.I)

# These exact commands cannot interpolate shell input, run a build hook or use
# user-selected paths. Everything else, including seemingly read-only curl GET,
# needs approval because a URL or argument can carry local information out.
_LOCAL_READ_ONLY = frozenset({"pwd", "ls", "ls -la", "git status --short", "cat README.md"})
_COMMAND_KEYS = frozenset({"command", "cmd", "code", "script", "input"})
_SECRETS = re.compile(
    r"~/\.ssh|/\.ssh/|id_(rsa|ed25519|ecdsa)\b|\.aws/credentials|\.netrc\b|(^|[\s/'\"])\.env\b"
    r"|\.hermes/(auth\.json|vault)|vault\.key|\bsecurity\s+(find|dump)-(generic|internet)-password|dump-keychain"
    r"|Cookies(\.binarycookies)?\b|Login Data\b|keychain-db",
    re.I)

_tainted: Dict[str, float] = {}
_lock = threading.Lock()


def _state_path() -> Path:
    """Profile-scoped state. Tests replace this path with a private temp directory."""
    from hermes_constants import get_hermes_home

    return Path(get_hermes_home()) / ".alice-egress" / "tainted.sqlite3"


def _has_remote_read(session_id: str, *, mark: bool = False) -> bool:
    """Durable, fail-closed taint; no raw session identifiers stored on disk.

    `mark=True` commits *before* a remote tool runs so an interrupted process
    cannot lose knowledge of the first exposure. SQLite serializes the test and
    insert across competing plugin processes. A DB failure raises to the blocking
    pre-tool hook; it must never be interpreted as an unseen session.
    """
    path = _state_path()
    directory = path.parent
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or path.is_symlink():
        raise OSError("egress state cannot be a symlink")
    key = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    conn = sqlite3.connect(str(path), timeout=3)
    try:
        os.chmod(path, 0o600)
        conn.execute("CREATE TABLE IF NOT EXISTS tainted_sessions (id TEXT PRIMARY KEY)")
        # Write first, then decide whether the session was already contaminated.
        # BEGIN IMMEDIATE also avoids concurrent 'first' reads on the same ID.
        conn.execute("BEGIN IMMEDIATE")
        was_seen = conn.execute("SELECT 1 FROM tainted_sessions WHERE id=?", (key,)).fetchone()
        if mark:
            conn.execute("INSERT OR IGNORE INTO tainted_sessions (id) VALUES (?)", (key,))
        conn.commit()
        return was_seen is not None
    finally:
        conn.close()


def observe(session_id: str, tool_name: str, now: Optional[float] = None) -> None:
    """After a tool ran: reading outside content taints the session."""
    if session_id and tool_name and (READS_OUTSIDE.match(tool_name) or _REMOTE_TOOLS.match(tool_name)):
        _has_remote_read(session_id, mark=True)
        with _lock:
            _tainted[session_id] = time.time() if now is None else now
            if len(_tainted) > 500:
                for key, _ in sorted(_tainted.items(), key=lambda kv: kv[1])[:100]:
                    _tainted.pop(key, None)


def tainted(session_id: str, now: Optional[float] = None) -> bool:
    with _lock:
        since = _tainted.get(session_id)
    return since is not None and (time.time() if now is None else now) - since < TAINT_TTL


def _command(args: Any) -> str:
    if isinstance(args, dict):
        for key in ("command", "code", "cmd", "script", "input"):
            if isinstance(args.get(key), str):
                return args[key]
    return str(args or "")


def _safe_local_command(tool_name: str, args: Any) -> bool:
    # A second argument field may alter the execution even if "command" looks
    # harmless; never ignore unknown fields, arrays of commands or scripts.
    if tool_name not in {"terminal", "shell", "bash", "run_command", "exec_command"}:
        return False
    if isinstance(args, str):
        return args in _LOCAL_READ_ONLY
    if not isinstance(args, dict) or len(args) != 1:
        return False
    key, value = next(iter(args.items()))
    return key in _COMMAND_KEYS and isinstance(value, str) and value in _LOCAL_READ_ONLY


def risk(tool_name: str, args: Any) -> Optional[str]:
    """What a command could do that needs the person, or None."""
    if tool_name not in RUNS_CODE:
        return None
    if _safe_local_command(tool_name, args):
        return None
    command = _command(args)
    if _SECRETS.search(command):
        return "leer claves o secretos"
    return "enviar datos fuera de tu Mac o leer información privada"


def check(tool_name: str, args: Any, session_id: str) -> Optional[Dict[str, str]]:
    """A directive for Hermes' pre_tool_call, or None to let the call run: ``approve`` sends it
    through Hermes' own approval card, with the exact command, so only the person's yes runs it.
    The rule key includes the complete tool arguments: "always allow" cannot cover a
    different command field or another interpreter tool."""
    if _REMOTE_TOOLS.fullmatch(tool_name or "") and tool_name not in RUNS_CODE:
        if not isinstance(session_id, str) or not session_id.strip():
            return {"action": "block", "message":
                    "No se puede verificar la sesión para acceder a la red."}
        # Unseen sessions may perform their FIRST web read without an approval
        # loop; record it durably first. Later requests need explicit approval.
        seen = _has_remote_read(session_id, mark=True)
        if not seen:
            return None
        what = "enviar datos mediante una URL, búsqueda o acción del navegador"
    elif tool_name in RUNS_CODE:
        # A missing, expired or process-lost taint record is NOT proof of safety.
        # One strict rule for every session closes restart and long-lived-chat gaps.
        what = risk(tool_name, args)
        if not what:
            return None
        if not isinstance(session_id, str) or not session_id.strip():
            return {"action": "block", "message":
                    "No se puede verificar la sesión para ejecutar este comando."}
        # An approved code command can itself fetch untrusted content. Record
        # that possible exposure before execution, not only for web_* tools.
        _has_remote_read(session_id, mark=True)
    else:
        return None
    # Bind "always allow" to the complete tool/arguments, not merely the first
    # command field (which can be accompanied by another executable field).
    request = json.dumps({"tool": tool_name, "args": args}, sort_keys=True,
                         separators=(",", ":"), ensure_ascii=False)
    return {"action": "approve",
            "message": f"Esta operación podría {what}. "
                       "Una página o mensaje malicioso podría haberlo pedido: apruébalo solo si lo has pedido tú.",
            "rule_key": "alice-egress:" + hashlib.sha256(request.encode("utf-8")).hexdigest()}
