"""Alice learns on her own: skills she writes are kept at once, unless they look injected.

Hermes can hold every skill write for the person's approval (``skills.write_approval``), which
stops a web page from planting lasting instructions — but nobody ever saw the queue: lessons the
person asked for ("learn it for next time") and Hermes' own after-conversation reviews piled up
unapplied for months. The gate stays on; this reviews each staged write as soon as it lands and
applies it, holding back only the ones that read like an injection rather than a lesson:

- sending data or files somewhere (webhooks, pastebins, "email/forward/upload … to");
- turning off protections or approvals, or acting without asking;
- secrets or keys written into a skill;
- shell that fetches and runs remote code, or deletes broadly;
- "ignore previous instructions" and similar.

A held write stays in Hermes' queue (``/skills pending``) with the reason logged. Every decision
goes to ``<home>/.alice/learned.jsonl``: what was learned, when, and what was held and why.
"""

from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

LOG = Path(".alice") / "learned.jsonl"
_lock = threading.Lock()

_RISKS: List[Tuple[str, re.Pattern]] = [
    ("sends data out", re.compile(
        r"(webhook\.site|requestbin|pastebin|ngrok\.io|pipedream|hookb\.in|transfer\.sh|discord(app)?\.com/api/webhooks)"
        r"|\b(send|post|upload|forward|exfiltrat\w*|email|mail|leak)\b[^\n]{0,60}\b(to|a)\b[^\n]{0,40}(https?://|\S+@\S+\.\w+)",
        re.I)),
    ("disables protections", re.compile(
        r"\b(disable|turn off|bypass|skip|ignore|desactiva\w*|salta\w*)\b[^\n]{0,40}"
        r"\b(approval|confirm\w*|safety|security|guard\w*|aprobaci\w+|confirmaci\w+|seguridad|vault)\b"
        r"|without (asking|confirmation|approval)|sin (preguntar|confirmar|pedir permiso)|write_approval|yolo",
        re.I)),
    ("overrides instructions", re.compile(
        r"ignore (all |any )?(previous|prior|above|earlier) (instructions|rules)|disregard (the )?(system|previous)"
        r"|ignora (las )?instrucciones (anteriores|previas)|you are now|new system prompt", re.I)),
    ("stores a secret", re.compile(
        r"(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[bp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}"
        r"|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(password|contraseña|api[_ -]?key|token|secret)\b\s*[:=]\s*\S{6,})",
        re.I)),
    ("runs remote code", re.compile(
        r"(curl|wget)[^\n|]{0,200}\|\s*(ba|z)?sh\b|base64\s+(-d|--decode)[^\n]{0,80}\|\s*(ba|z)?sh"
        r"|rm\s+-rf\s+(/|~|\$HOME)(\s|$)", re.I)),
]


def _text(record: Dict[str, Any]) -> str:
    """Everything the write would put into a skill."""
    payload = record.get("payload") or {}
    return json.dumps(payload, ensure_ascii=False)


def review(record: Dict[str, Any]) -> Optional[str]:
    """None when the write reads like a lesson; the reason when it should be held."""
    text = _text(record)
    for reason, pattern in _RISKS:
        if pattern.search(text):
            return reason
    return None


def _log(home: Path, entry: Dict[str, Any]) -> None:
    path = Path(home) / LOG
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


_DESCRIPTION = re.compile(r"^(description:\s*)(.+)$", re.M)
DESCRIPTION_LIMIT = 60


def _short(description: str) -> str:
    """One sentence within Hermes' 60-character budget, ending with a period."""
    text = description.strip().strip("'\"").strip()
    first = re.split(r"(?<=[.;:—–])\s|\s[—–-]\s", text)[0].rstrip(".;:—– ")
    if len(first) > DESCRIPTION_LIMIT - 1:
        first = first[:DESCRIPTION_LIMIT - 1].rsplit(" ", 1)[0].rstrip(",;: ")
    return first + "."


def _shorten_descriptions(value: Any) -> Any:
    """The same write with every skill description cut to fit (an older Hermes staged longer ones)."""
    if isinstance(value, dict):
        return {k: _shorten_descriptions(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_shorten_descriptions(v) for v in value]
    if isinstance(value, str) and value.lstrip().startswith("---") and "description:" in value:
        return _DESCRIPTION.sub(lambda m: m.group(1) + _short(m.group(2)), value, count=1)
    return value


# Writes that can no longer apply: the skill they patch is gone, or they were staged incomplete.
_OBSOLETE = re.compile(r"not found in active profile|content is required", re.I)


def _apply(payload: Dict[str, Any]) -> Dict[str, Any]:
    from tools.skill_manager_tool import apply_skill_pending

    try:
        result = json.loads(apply_skill_pending(payload))
    except Exception as exc:  # a broken write must not stop the others
        return {"success": False, "error": f"{type(exc).__name__}: {exc}"}
    if not result.get("success") and "Description is" in str(result.get("error")):
        payload = _shorten_descriptions(payload)
        try:
            result = json.loads(apply_skill_pending(payload))
        except Exception as exc:
            return {"success": False, "error": f"{type(exc).__name__}: {exc}"}
    if not result.get("success") and "already exists" in str(result.get("error")):
        # A later lesson about a skill written meanwhile: it replaces it.
        try:
            result = json.loads(apply_skill_pending(_create_as_edit(payload)))
        except Exception as exc:
            return {"success": False, "error": f"{type(exc).__name__}: {exc}"}
    return result


def _create_as_edit(value: Any) -> Any:
    """A ``create`` of a skill that now exists, as a rewrite of its SKILL.md."""
    if isinstance(value, dict):
        out = {k: _create_as_edit(v) for k, v in value.items()}
        if out.get("action") == "create" and isinstance(out.get("content"), str):
            return {"action": "write_file", "name": out.get("name"), "file_path": "SKILL.md",
                    "file_content": out["content"]}
        return out
    if isinstance(value, list):
        return [_create_as_edit(v) for v in value]
    return value


def run(home: Path) -> Dict[str, Any]:
    """Apply every staged skill write that passes review; hold the rest. Idempotent."""
    from tools import write_approval as wa

    learned, held, failed = [], [], []
    with _lock:
        for record in wa.list_pending(wa.SKILLS):
            summary = str(record.get("summary") or record.get("id"))
            reason = review(record)
            if reason:
                held.append({"id": record.get("id"), "summary": summary, "reason": reason})
                continue
            result = _apply(record.get("payload") or {})
            if result.get("success"):
                wa.discard_pending(wa.SKILLS, record["id"])
                learned.append(summary)
                _log(home, {"at": time.time(), "learned": summary, "origin": record.get("origin")})
            elif _OBSOLETE.search(str(result.get("error"))):
                wa.discard_pending(wa.SKILLS, record["id"])
                _log(home, {"at": time.time(), "dropped": summary, "reason": str(result.get("error"))[:160]})
            else:
                failed.append({"id": record.get("id"), "summary": summary, "error": str(result.get("error"))[:200]})
        for item in held:
            _log(home, {"at": time.time(), "held": item["summary"], "reason": item["reason"], "id": item["id"]})
    return {"learned": learned, "held": held, "failed": failed}


def run_soon(home: Path, delay: float = 0.0) -> None:
    """In the background: a skill write never waits on this, and this never breaks a turn."""
    def work():
        if delay:
            time.sleep(delay)
        try:
            run(home)
        except Exception:
            pass

    threading.Thread(target=work, name="alice-skill-keeper", daemon=True).start()
