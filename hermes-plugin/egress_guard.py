"""Tainted egress: after reading the web, what could carry data out asks the person first.

Meta's Muse keeps part of the trust decision below the model: once a process has read outside
content, its ability to send data out is held to tighter rules. Alice runs on the person's Mac
with their permissions, so this is the same idea at the tool layer, deterministic and cheap:

1. A session becomes **tainted** when an agent reads content it did not write and the person
   did not type: a web page, a search result, an email, a downloaded file.
2. In a tainted session, a terminal or code command that could **send data out** (an upload or
   POST, a raw socket, copying to another machine, mailing) or **read secrets** (SSH keys, .env
   files, the vault, the Keychain, browser cookies) is not run on the agent's say-so. Hermes
   shows the person the exact command on their approval card; only their yes lets it through.

Everything else — browsing, reading files, building the app, controlling the Mac — is untouched.
A prompt injection on a web page can still make the model *want* to exfiltrate; it cannot make
it happen without the person seeing it.
"""
from __future__ import annotations

import re
import threading
import time
from typing import Any, Dict, Optional

TAINT_TTL = 6 * 3600
# Tools that bring outside words into the conversation.
READS_OUTSIDE = re.compile(
    r"^(web_extract|web_search|browser_\w+|browser-use\w*|fetch\w*|read_email\w*|himalaya\w*|gmail\w*|"
    r"mcp_\w*(gmail|mail|web|browse|fetch|scrape)\w*)$", re.I)
# Tools whose arguments run code or commands.
RUNS_CODE = {"terminal", "execute_code", "shell", "bash", "run_command"}

_EGRESS = re.compile(
    r"\bcurl\b[^\n]*?(\s-(d|F|T)\b|--data\w*|--form|--upload-file|-X\s*(POST|PUT|PATCH)|--request\s+(POST|PUT|PATCH))"
    r"|\bwget\b[^\n]*--post-(data|file)"
    r"|\b(nc|ncat|netcat|socat|telnet)\b\s+\S+"
    r"|\b(scp|sftp)\b\s|\brsync\b[^\n]*\s\S+@\S+:|\bssh\b\s+\S+@"
    r"|\b(sendmail|mail|mutt)\b\s|\bhimalaya\b[^\n]*\b(send|forward|write)\b"
    r"|requests\.(post|put|patch)\(|urllib\.request\.urlopen\([^)]*data=|http\.client|socket\.socket\("
    r"|fetch\([^)]*method:\s*['\"](POST|PUT)",
    re.I)
_SECRETS = re.compile(
    r"~/\.ssh|/\.ssh/|id_(rsa|ed25519|ecdsa)\b|\.aws/credentials|\.netrc\b|(^|[\s/'\"])\.env\b"
    r"|\.hermes/(auth\.json|vault)|vault\.key|\bsecurity\s+(find|dump)-(generic|internet)-password|dump-keychain"
    r"|Cookies(\.binarycookies)?\b|Login Data\b|keychain-db",
    re.I)

_tainted: Dict[str, float] = {}
_lock = threading.Lock()


def observe(session_id: str, tool_name: str, now: Optional[float] = None) -> None:
    """After a tool ran: reading outside content taints the session."""
    if session_id and tool_name and READS_OUTSIDE.match(tool_name):
        with _lock:
            _tainted[session_id] = now or time.time()
            if len(_tainted) > 500:
                for key, _ in sorted(_tainted.items(), key=lambda kv: kv[1])[:100]:
                    _tainted.pop(key, None)


def tainted(session_id: str, now: Optional[float] = None) -> bool:
    with _lock:
        since = _tainted.get(session_id)
    return since is not None and (now or time.time()) - since < TAINT_TTL


def _command(args: Any) -> str:
    if isinstance(args, dict):
        for key in ("command", "code", "cmd", "script", "input"):
            if isinstance(args.get(key), str):
                return args[key]
    return str(args or "")


def risk(tool_name: str, args: Any) -> Optional[str]:
    """What a command could do that needs the person, or None."""
    if tool_name not in RUNS_CODE:
        return None
    command = _command(args)
    if _SECRETS.search(command):
        return "leer claves o secretos"
    if _EGRESS.search(command):
        return "enviar datos fuera de tu Mac"
    return None


def check(tool_name: str, args: Any, session_id: str) -> Optional[Dict[str, str]]:
    """A directive for Hermes' pre_tool_call, or None to let the call run: ``approve`` sends it
    through Hermes' own approval card, with the exact command, so only the person's yes runs it.
    The rule key is the command itself: "always allow" can only ever cover that same command."""
    import hashlib

    if not session_id or not tainted(session_id):
        return None
    what = risk(tool_name, args)
    if not what:
        return None
    command = _command(args)
    return {"action": "approve",
            "message": f"Esta conversación ha leído contenido de internet, y este comando podría {what}. "
                       "Una web maliciosa podría haberlo pedido: apruébalo solo si lo has pedido tú.",
            "rule_key": "alice-egress:" + hashlib.sha256(command.encode("utf-8")).hexdigest()[:16]}
