"""Lessons from the person's corrections, kept so the same mistake is not made twice.

When the person corrects Alice ("no, te pedí el de cordero", "eso no, mira también lo de esta
mañana", "otra vez con asteriscos"), that correction is the most valuable feedback there is.
Once a conversation is quiet, this looks for them and turns the ones that generalise into a
standing instruction in Alice's memory — which every conversation reads — so it holds next
time without anyone having to say "learn it".

Built to be cheap and hard to fool:

* **No model call without a correction.** Replies are scanned with plain patterns first; most
  conversations have none and cost nothing.
* **The person's words only.** A lesson must quote the person's correction, verified against
  what they actually wrote (tool output and injected text are stripped), so a web page cannot
  plant one.
* **Only what generalises.** "Wrong date, it was the 12th" is a fix, not a lesson; "when I ask
  what I had today, include the morning" is. The model is asked for the latter only, at most
  ``MAX_LESSONS`` per conversation, and a lesson that reads like an injection is dropped.
"""
from __future__ import annotations

import re
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

MAX_LESSONS = 2
MAX_LESSON = 220
MAX_REPLY = 700

# A turn that tells the assistant it got something wrong, in Spanish or English.
CORRECTION = re.compile(
    r"^\s*(no[,.!\s]|nop\b|nope\b)"
    r"|\b(eso no|as[ií] no|no es eso|no era eso|no te ped[ií]|te ped[ií]|te he dicho|te dije|ya te dije"
    r"|otra vez|de nuevo (con|lo)|mal\b|est[aá] mal|incorrect[oa]|te equivocas|te has equivocado|equivocad[oa]"
    r"|no me (sirve|vale|gusta)|no hace falta que|deja de|no vuelvas a|nunca m[aá]s|siempre (que|haz|pon)"
    r"|por qu[eé] no (me|lo|has)|no (lo )?has (hecho|mirado|comprobado)|se te ha olvidado|te olvidaste|olvidaste"
    r"|that'?s (wrong|not)|not what i (asked|meant)|i (said|told you)|you (forgot|missed)|don'?t (do|ever)|stop \w+ing)",
    re.IGNORECASE)


def corrections(messages: Sequence[Dict[str, Any]], person_text: Callable[[Dict[str, Any]], str]
                ) -> List[Tuple[str, str]]:
    """(what the assistant said, what the person answered) for each turn that corrects it."""
    pairs: List[Tuple[str, str]] = []
    last_reply = ""
    for message in messages:
        role = message.get("role")
        if role == "assistant":
            content = message.get("content")
            if isinstance(content, str) and content.strip():
                last_reply = content.strip()
            continue
        if role != "user" or message.get("_compressed_summary"):
            continue
        said = person_text(message)
        if said and last_reply and CORRECTION.search(said):
            pairs.append((last_reply[-MAX_REPLY:], said[:1000]))
        last_reply = ""
    return pairs[-8:]


def prompt(pairs: Sequence[Tuple[str, str]], memory: Sequence[str]) -> List[Dict[str, str]]:
    system = (
        "You improve a personal assistant from the corrections its person gave it. Each item is the "
        "assistant's reply and the person's answer correcting it.\n"
        "Write a lesson only when the correction shows a way of working the assistant should follow "
        "from now on in similar situations — a rule, not a one-off fix. Good: \"When asked what they had "
        "today, include events earlier today, not only upcoming ones.\" Not a lesson: a wrong number "
        "corrected once, a change of mind, a new request.\n"
        "Each lesson: one short imperative sentence for the assistant, in the language the person uses, "
        "general enough to apply next time, specific enough to act on. Give `evidence`: the person's "
        "exact words copied from their correction (fragments joined by \"...\" allowed). Skip anything "
        "already covered by the standing instructions listed. At most two. If nothing qualifies, return "
        "an empty list. JSON only: {\"lessons\": [{\"text\": \"...\", \"evidence\": \"...\"}]}"
    )
    items = "\n\n".join(f"Assistant: {reply}\nPerson: {said}" for reply, said in pairs)
    known = "\n".join(f"- {entry}" for entry in memory) or "(none)"
    return [{"role": "system", "content": system},
            {"role": "user", "content": f"Standing instructions now:\n{known}\n\nCorrections:\n{items}"}]


def accepted(lessons: Sequence[Dict[str, Any]], said: Sequence[str], memory: Sequence[str],
             quoted: Callable[[str, Sequence[str]], bool], plain: Callable[[str], str],
             risky: Callable[[str], Optional[str]]) -> List[Dict[str, str]]:
    known = {plain(entry) for entry in memory}
    keep: List[Dict[str, str]] = []
    for lesson in lessons:
        text = " ".join(str(lesson.get("text") or "").split())
        evidence = str(lesson.get("evidence") or "").strip()
        if not (10 <= len(text) <= MAX_LESSON) or "§" in text or plain(text) in known:
            continue
        if not quoted(evidence, said) or risky(text):
            continue
        known.add(plain(text))
        keep.append({"text": text, "evidence": evidence})
        if len(keep) >= MAX_LESSONS:
            break
    return keep


def review(messages: Sequence[Dict[str, Any]], keeper, ask: Callable[[List[Dict[str, str]]], str], *,
           person_text: Callable[[Dict[str, Any]], str], quoted, plain, risky,
           session: str = "", profile: str = "") -> List[Dict[str, Any]]:
    """One look for corrections; the lessons kept as standing instructions in memory."""
    pairs = corrections(messages, person_text)
    if not pairs:
        return []
    memory = keeper.files.entries("memory")
    parsed = _parse(ask(prompt(pairs, memory)))
    changes = []
    for lesson in accepted(parsed, [said for _, said in pairs], memory, quoted, plain, risky):
        change = keeper.learn("memory", lesson["text"], replaces=None, evidence=lesson["evidence"],
                              session=session, profile=profile)
        if change:
            changes.append(change)
    return changes


def _parse(reply: str) -> List[Dict[str, Any]]:
    import json

    text = reply or ""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return []
    try:
        data = json.loads(text[start:end + 1])
    except ValueError:
        return []
    items = data.get("lessons") if isinstance(data, dict) else None
    return [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []
