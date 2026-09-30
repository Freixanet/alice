"""Questions the agent asks the person without stopping its work.

``clarify`` holds the whole turn until the person answers, so a purchase stood still while
Alice waited for an address — and the model, knowing that, asked in plain text instead,
with no card to answer in. ``ask_person`` returns at once: Alice draws the questions as a
card from the tool call, the agent carries on with whatever does not depend on them, and
the answer comes back as the person's own message, ``[respuesta:<id>] <value>`` per line —
folded into the running turn when Hermes steers busy input, or starting the next one.

While a question is open the task's goal is parked, so the judge does not send the agent
back every few seconds to repeat that it is waiting (it did, twelve times). The answer
releases it.

Personal and delivery details (name, ID, address, phone, email) are kept once given, in
``alice/details.json`` under Hermes' home (0600), and edited in Alice's Settings. A
question for a detail already kept is answered from there and never reaches the person.
"""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

# The details Alice keeps and the form in Settings shows, in that order.
FIELDS = ("name", "surname", "id", "address", "postcode", "city", "province", "phone", "email", "country", "currency")
MAX_QUESTIONS = 10
MAX_CHOICES = 6
WAIT_SECONDS = 3600
ANSWER = re.compile(r"^\[respuesta:([A-Za-z0-9_.-]{1,40})\]\s?(.*)$")
# Signing in is the sign-in card's (browser_vault_save_login): it already offers sign in, a new
# account or none. Asked here as well, the person was asked the same thing twice, and asked
# before any site had even required it.
SIGN_IN = re.compile(r"inici\w* sesi|cuenta|contrase|log ?in|sign ?(in|up)|account|password|registr", re.I)

SCHEMA: Dict[str, Any] = {
    "name": "ask_person",
    "description": (
        "Ask the person something WITHOUT stopping your work: returns at once, Alice shows the "
        "questions as a card, and their answer arrives later as their message "
        "('[respuesta:<id>] <value>'). Use it instead of asking in the text of your reply and "
        "instead of clarify whenever there is still work you can do meanwhile (search, open the "
        "shop, fill the basket). Personal or delivery details (field) are answered from what the "
        "person already gave when known — check 'known' in the result before asking again. "
        "Never for passwords, card numbers or codes: those go through the secure cards — and never "
        "to ask whether the person has an account: the sign-in card already lets them sign in, "
        "create one or say they have none. Do nothing that depends on an open question until "
        "its answer arrives; carry on only with what does not."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "description": "One short line over the card, e.g. 'Datos de envío'."},
            "questions": {
                "type": "array",
                "maxItems": MAX_QUESTIONS,
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string", "description": "Short id, e.g. 'pago' or 'address'."},
                        "question": {"type": "string"},
                        "choices": {"type": "array", "items": {"type": "string"}, "maxItems": MAX_CHOICES,
                                    "description": "Options to tap. Leave out for a typed answer."},
                        "multi": {"type": "boolean", "description": "More than one choice may be picked."},
                        "field": {"type": "string", "enum": list(FIELDS),
                                  "description": "A personal/delivery detail: kept once given, never asked again."},
                    },
                    "required": ["id", "question"],
                },
            },
        },
        "required": ["questions"],
    },
}


def _dir(home: Path) -> Path:
    path = Path(home) / "alice"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _read(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write(path: Path, data: Dict[str, Any]) -> None:
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


# MARK: Details

def load_details(home: Path) -> Dict[str, str]:
    raw = _read(_dir(home) / "details.json")
    return {key: str(raw[key]).strip() for key in FIELDS if str(raw.get(key) or "").strip()}


def save_details(home: Path, values: Dict[str, Any]) -> Dict[str, str]:
    """Replaces the kept details with ``values`` (an empty value forgets that detail)."""
    kept = {key: " ".join(str(values.get(key) or "").split())[:200] for key in FIELDS}
    kept = {key: value for key, value in kept.items() if value}
    _write(_dir(home) / "details.json", kept)
    return kept


def _remember(home: Path, field: str, value: str) -> None:
    value = " ".join(str(value or "").split())[:200]
    if field in FIELDS and value:
        details = load_details(home)
        details[field] = value
        save_details(home, details)


# MARK: Open questions

def _asks_path(home: Path) -> Path:
    return _dir(home) / "asks.json"


def open_questions(home: Path, session_key: str) -> Dict[str, Dict[str, Any]]:
    return dict((_read(_asks_path(home)).get(session_key) or {}).get("questions") or {})


def _set_open(home: Path, session_key: str, questions: Dict[str, Dict[str, Any]]) -> None:
    data = _read(_asks_path(home))
    # Questions nobody answered in a day are dropped: the goal stopped waiting long before.
    since = time.time() - 86400
    data = {key: value for key, value in data.items() if float(value.get("at") or 0) >= since}
    if questions:
        data[session_key] = {"at": time.time(), "questions": questions}
    else:
        data.pop(session_key, None)
    _write(_asks_path(home), data)


def _goal(session_key: str):
    try:
        from hermes_cli.goals import GoalManager
    except ImportError:
        return None
    manager = GoalManager(session_id=session_key)
    return manager if manager.is_active() else None


def _normalized(args: Dict[str, Any]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    seen = set()
    for raw in (args.get("questions") or [])[:MAX_QUESTIONS]:
        if not isinstance(raw, dict):
            continue
        text = " ".join(str(raw.get("question") or "").split())[:300]
        qid = re.sub(r"[^A-Za-z0-9_.-]", "", str(raw.get("id") or ""))[:40] or f"q{len(out) + 1}"
        if not text or qid in seen:
            continue
        seen.add(qid)
        field = str(raw.get("field") or "")
        choices = [" ".join(str(c).split())[:80] for c in (raw.get("choices") or []) if str(c).strip()]
        out.append({"id": qid, "question": text, "choices": choices[:MAX_CHOICES],
                    "multi": bool(raw.get("multi")), "field": field if field in FIELDS else ""})
    return out


def run_tool(home: Path, args: Dict[str, Any], session_key: str) -> Dict[str, Any]:
    questions = _normalized(args or {})
    if not questions:
        return {"ok": False, "error": "Give at least one question with an id and its text."}
    if any(SIGN_IN.search(q["question"] + " " + " ".join(q["choices"])) for q in questions):
        return {"ok": False, "error": (
            "Not asked: accounts and sign-in are never asked with ask_person. Carry on without an "
            "account; only if the site itself requires signing in, call browser_vault_save_login on "
            "that page — its card lets the person sign in, create an account or say they have none.")}
    details = load_details(home)
    known = {q["id"]: details[q["field"]] for q in questions if q["field"] and q["field"] in details}
    asked = [q for q in questions if q["id"] not in known]
    if not asked:
        return {"ok": True, "asked": [], "known": known,
                "note": "Everything was already known: use these values and carry on."}
    if session_key:
        pending = open_questions(home, session_key)
        pending.update({q["id"]: {"field": q["field"], "question": q["question"]} for q in asked})
        _set_open(home, session_key, pending)
        if (goal := _goal(session_key)) is not None:
            goal.wait_for_seconds(WAIT_SECONDS, reason="esperando la respuesta de la persona")
    return {
        "ok": True, "asked": [q["id"] for q in asked], "known": known,
        "note": ("The person sees the card now. Keep working on everything that does not depend on the "
                 "answer; do not repeat the question in your reply. The answer arrives as their message "
                 "'[respuesta:<id>] <value>'. If nothing else can be done, end your reply in one line "
                 "saying what you are waiting for."),
    }


def answers_in(text: Any) -> Dict[str, str]:
    """``{id: value}`` from a message of ``[respuesta:<id>] <value>`` lines."""
    if isinstance(text, list):  # multimodal content
        text = " ".join(str(part.get("text") or "") for part in text if isinstance(part, dict))
    found: Dict[str, str] = {}
    for line in str(text or "").splitlines():
        if match := ANSWER.match(line.strip()):
            found[match.group(1)] = match.group(2).strip()
    return found


def absorb(home: Path, session_key: str, messages: List[Dict[str, Any]]) -> bool:
    """Takes the answers in ``messages``: keeps the details, closes those questions, and
    lets the goal go on once none is open. True when anything was answered."""
    if not session_key:
        return False
    pending = open_questions(home, session_key)
    if not pending:
        return False
    answers: List[str] = []
    for message in messages:
        if message.get("role") != "user":
            continue
        for qid, value in answers_in(message.get("content")).items():
            if qid in pending:
                if field := pending[qid].get("field"):
                    _remember(home, field, value)
                    value = "(dato guardado)"
                answers.append(f"«{pending[qid].get('question') or qid}» → {value}")
                pending.pop(qid)
    if not answers:
        return False
    _set_open(home, session_key, pending)
    if (goal := _goal(session_key)) is not None:
        _amend_goal(goal, answers)
        if not pending:
            goal.stop_waiting()
    return True


def _amend_goal(goal, answers: List[str]) -> None:
    """The person's answers become part of the task itself.

    The judge reads the goal and the last reply. Kept as extra criteria, the answers lost to the
    original words: asked for 1 kg, the person chose 500 g on a card, and the judge kept sending the
    agent back for the kilo and to ask the flavour it had already been told."""
    state = goal.state
    decided = ("Decidido por la persona después, con ask_person — manda sobre lo pedido al principio; "
               "ya está preguntado y respondido: " + "; ".join(answers))
    state.goal = f"{state.goal}\n{decided}"
    contract = getattr(state, "contract", None)
    if contract is not None and getattr(contract, "outcome", ""):
        contract.outcome = f"{contract.outcome}\n{decided}"
    goal._save()


def prompt(home: Optional[Path] = None) -> str:
    known = ", ".join(sorted(load_details(home))) if home else ""
    return (
        "Para preguntar a la persona mientras trabajas, usa `ask_person` (una tarjeta en Alice), nunca el "
        "texto de tu respuesta; sigue con lo que no dependa de la respuesta. Nombre, NIF, dirección, CP, "
        "localidad, provincia, teléfono y email van con `field`: si ya los dio, vuelven en `known`. País y "
        "moneda no se preguntan: Alice los deduce. Para entrar en una tienda no preguntes si tiene cuenta: "
        "abre `browser_vault_save_login`. Nunca ofrezcas opciones que no has visto: mira qué tiene la tienda "
        "y pregunta entre eso; si preguntaste antes, repite el mismo `id` con las opciones reales. Productos "
        "con precio van como tarjetas (`purchase_options`), no como pregunta. No preguntes dos veces lo mismo."
        + (f" Ya guardados: {known}." if known else "")
    )
