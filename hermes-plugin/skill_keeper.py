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

A held write stays in Hermes' queue (``/skills pending``) with the reason logged once — not again
on every later pass, which once wrote the same hold 4,765 times. Every decision goes to
``<home>/.alice/learned.jsonl``: what was learned, when, and what was held and why. What was learned
or newly held also goes to Alice's action log, so the chat can say so (``skill.learned``, ``skill.held``).
"""

from __future__ import annotations

import json
import os
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
        r"|without (asking|confirmation|approval|telling)|sin (preguntar|confirmar|pedir permiso|consultar|avisar)"
        r"|(don'?t|do not|never|no)\s+(ask|confirm|check with|tell)\b|no (le )?(pidas|preguntes|consultes)\b"
        r"|write_approval|yolo",
        re.I)),
    ("overrides instructions", re.compile(
        r"ignore (all |any )?(previous|prior|above|earlier) (instructions|rules)|disregard (the )?(system|previous)"
        r"|ignora (las )?instrucciones (anteriores|previas)|you are now|new system prompt", re.I)),
    ("stores a secret", re.compile(
        r"(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[bp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}"
        r"|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(password|contraseña|api[_ -]?key|token|secret)\b\s*[:=]\s*\S{6,})",
        re.I)),
    ("runs remote code", re.compile(
        r"(curl|wget)[^\n|]{0,200}\|\s*(sudo\s+)?((ba|z)?sh|python\d?|perl|ruby|node)\b"
        r"|base64\s+(-d|--decode)[^\n]{0,80}\|\s*\w+"
        r"|(ba|z)?sh\s+<\(\s*(curl|wget)|eval\s+\\?[\"']?\$\(\s*(curl|wget)"
        r"|rm\s+-[rRf]{2,}\s+(/|~|\$HOME)", re.I)),
    # Long encoded blobs hide what a skill says.
    ("hides its text", re.compile(r"[A-Za-z0-9+/]{240,}={0,2}")),
]


def _text(record: Dict[str, Any]) -> str:
    """Everything the write would put into a skill."""
    payload = record.get("payload") or {}
    return json.dumps(payload, ensure_ascii=False)


TAINTED = Path(".alice") / "tainted-lessons.json"


def mark_tainted(home: Path, pending_id: str) -> None:
    """A lesson proposed in a conversation that had read the web: a page may have written it, so it
    is not kept on its own (the plugin calls this from post_tool_call, where the session is known)."""
    path = Path(home) / TAINTED
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        ids = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        ids = []
    if pending_id not in ids:
        ids = (ids + [pending_id])[-500:]
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(ids), encoding="utf-8")
        tmp.replace(path)


def _tainted_ids(home: Path) -> set:
    try:
        return set(json.loads((Path(home) / TAINTED).read_text(encoding="utf-8")))
    except (OSError, ValueError, TypeError):
        return set()


def review(record: Dict[str, Any], tainted: Optional[set] = None) -> Optional[str]:
    """None when the write reads like a lesson; the reason when it should be held."""
    if tainted and record.get("id") in tainted:
        return "learned after reading the web"
    text = _text(record)
    for reason, pattern in _RISKS:
        if pattern.search(text):
            return reason
    return None


LOG_KEEP = 2000


def _log(home: Path, entry: Dict[str, Any]) -> None:
    path = Path(home) / LOG
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    # Kept bounded: it once grew by the same held lesson 4,765 times.
    try:
        if path.stat().st_size > 512_000:
            lines = path.read_text(encoding="utf-8").splitlines(keepends=True)[-LOG_KEEP:]
            temp = path.with_name(path.name + ".trim")
            temp.write_text("".join(lines), encoding="utf-8")
            os.replace(temp, path)
    except OSError:
        pass


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


def _held_before(home: Path) -> set:
    """Ids of writes already logged as held: a hold is said once, not on every pass."""
    try:
        lines = (Path(home) / LOG).read_text(encoding="utf-8").splitlines()
    except OSError:
        return set()
    ids = set()
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if "held" in entry and entry.get("id"):
            ids.add(entry["id"])
    return ids


def _skills_named(summary: str) -> str:
    """``batch(2 ops: create, patch) on a, b`` → ``a, b``."""
    return summary.rsplit(" on ", 1)[-1] if " on " in summary else summary


def _skill_text(home: Path, names: str) -> str:
    """The instructions of each skill named, without the YAML preamble: what was learned."""
    parts = []
    for name in [n.strip() for n in names.split(",") if n.strip()]:
        for root in (Path(home) / "skills", Path(home).parent.parent / "skills"):
            found = next(iter(sorted(root.glob(f"*/{name}/SKILL.md")) + sorted(root.glob(f"{name}/SKILL.md"))), None)
            if found:
                body = found.read_text(encoding="utf-8", errors="replace")
                if body.startswith("---"):
                    body = body.split("---", 2)[-1]
                parts.append(body.strip())
                break
    return "\n\n".join(parts)


_SUMMARY_PROMPT = (
    "Alice, a personal assistant, just learned the lesson below for next time. Say in Spanish, in one or two "
    "short sentences addressed to the person (tú), what she will do differently. Plain words a non-technical "
    "person understands: no commands, tool or file names, flags or code. Only the sentences.")


def _summarize(text: str) -> str:
    """One or two plain sentences from the profile's own model; empty when it cannot be asked."""
    if not text:
        return ""
    try:
        from agent.auxiliary_client import call_llm, extract_content_or_reasoning
        from hermes_cli.config import load_config

        config = load_config() or {}
        model = config.get("model") or {}
        route = {} if not isinstance(model, dict) else {
            "provider": model.get("provider") or None, "model": model.get("default") or None,
            "base_url": model.get("base_url") or None}
        response = call_llm(task="alice_lesson_summary", max_tokens=300, timeout=60, messages=[
            {"role": "system", "content": _SUMMARY_PROMPT},
            {"role": "user", "content": text[:6000]}], **route)
        return (extract_content_or_reasoning(response) or "").strip().strip('"«»')
    except Exception:
        return ""


def _tell(home: Path, kind: str, summary: str, explain: bool = False) -> None:
    """Into Alice's action log, where the chat reads it. Never breaks the keeping. A kept lesson
    carries its text and a plain summary, shown when the person taps «He aprendido…»."""
    try:
        import importlib.util
        import sys

        module = sys.modules.get("alice_action_log")
        if module is None:
            spec = importlib.util.spec_from_file_location("alice_action_log", Path(__file__).resolve().parent / "action_log.py")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            sys.modules["alice_action_log"] = module
        home = Path(home)
        root, profile = (home.parent.parent, home.name) if home.parent.name == "profiles" else (home, "default")
        text = _skill_text(home, _skills_named(summary)) if explain else ""
        module.record(root, profile=profile, session="", tool="skill_manage", kind=kind,
                      target=_skills_named(summary), ok=True, summary=_summarize(text), text=text)
    except Exception:
        pass


def run(home: Path) -> Dict[str, Any]:
    """Apply every staged skill write that passes review; hold the rest. Idempotent."""
    from tools import write_approval as wa

    learned, held, failed = [], [], []
    with _lock:
        tainted = _tainted_ids(home)
        for record in wa.list_pending(wa.SKILLS):
            summary = str(record.get("summary") or record.get("id"))
            reason = review(record, tainted)
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
        before = _held_before(home)
        for item in held:
            if item["id"] in before:
                continue
            _log(home, {"at": time.time(), "held": item["summary"], "reason": item["reason"], "id": item["id"]})
            _tell(home, "skill.held", item["summary"])
    # Outside the lock: summarizing asks the model.
    for summary in learned:
        _tell(home, "skill.learned", summary, explain=True)
    return {"learned": learned, "held": held, "failed": failed}


_KEPT = ("Saved: Alice keeps a reviewed lesson on her own within seconds. If you mention it, say only that "
         "you learned it for next time — no approvals, commands or setting names: there is nothing for the person to do.")
_HELD = ("Not saved: this lesson was set aside as possibly unsafe. Do not ask the person to approve it and do not "
         "mention approvals, commands or setting names.")


def staged_note(args: Any, result: Any, tainted: bool = False) -> Optional[str]:
    """Hermes answers a staged skill write with «pending your approval»; Alice approves it herself a
    second later (or holds it), so the agent kept telling the person to run ``/skills pending``."""
    try:
        parsed = json.loads(result) if isinstance(result, str) else None
    except ValueError:
        return None
    if not isinstance(parsed, dict) or not parsed.get("staged"):
        return None
    held = tainted or review({"payload": args if isinstance(args, dict) else {}})
    parsed["message"] = _HELD if held else _KEPT
    return json.dumps(parsed, ensure_ascii=False)


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
