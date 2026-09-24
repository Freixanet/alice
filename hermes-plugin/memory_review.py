"""A look back at each conversation for what the person said about themselves and was not
kept.

Hermes' agent saves to memory when it notices something worth keeping, and reviews the
conversation on its own every few turns. A short exchange ("vivo en Súria", two turns and
done) can end before either happens, and the fact is lost. This module closes that gap:
once a conversation has been quiet for a moment, it reads what *the person* wrote since the
last look — never the agent's replies, which would let it remember its own guesses — and
asks the agent's own model for durable facts about them.

A fact is kept only when:

* it comes with the person's words, quoted, and those words are really in the
  conversation (the model cannot invent evidence);
* it would still be true next month — where they live, their family, their work, a lasting
  preference; not a task or what they are doing today;
* it is not already in memory. When it updates an entry ("ahora vivo en…"), that entry is
  replaced, unless the person wrote it themselves by hand or from the app.

Every fact kept is a change in the memory keeper's history, with its origin, and can be
undone like any cleanup. Nothing here raises into a conversation.
"""
from __future__ import annotations

import json
import re
import unicodedata
from datetime import date
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence

# Enough for "vive en Súria con su pareja y dos hijos"; a paragraph is not a fact.
MAX_FACT = 220
MAX_FACTS = 5
# What the model reads: the person's recent words, not a whole archive.
MAX_TURNS = 30
MAX_TURN_CHARS = 2000
# Text tools and apps put inside a person's message that the person did not write.
_INJECTED = re.compile(r"<(system-reminder|context|attachment|memory-context|reminder)[^>]*>.*?</\1>",
                       re.DOTALL | re.IGNORECASE)
_MARKS = re.compile(r"[*_`~>#]")
_ELLIPSIS = re.compile(r"\s*(?:\.\.\.|…)\s*")


def _plain(text: str) -> str:
    folded = unicodedata.normalize("NFKC", text or "").casefold()
    folded = folded.replace("’", "'").replace("“", '"').replace("”", '"')
    return " ".join(_MARKS.sub(" ", folded).split())


def person_turns(messages: Iterable[Dict[str, Any]]) -> List[str]:
    """What the person wrote, without what tools injected into their messages."""
    turns = []
    for message in messages:
        if message.get("role") != "user" or message.get("_compressed_summary"):
            continue
        content = message.get("content")
        if isinstance(content, list):  # multimodal: only the text parts
            content = " ".join(str(p.get("text") or "") for p in content if isinstance(p, dict))
        text = _INJECTED.sub(" ", str(content or "")).strip()
        if text:
            turns.append(text[:MAX_TURN_CHARS])
    return turns[-MAX_TURNS:]


def quoted(evidence: str, turns: Sequence[str]) -> bool:
    """The evidence is the person's own words: each fragment (joined by an ellipsis) is in
    one of their messages, in order. Case, spacing and Markdown marks do not count."""
    parts = [_plain(p) for p in _ELLIPSIS.split(evidence or "") if _plain(p)]
    if not parts or sum(len(p) for p in parts) < 4:
        return False
    for turn in turns:
        haystack, at = _plain(turn), 0
        for part in parts:
            found = haystack.find(part, at)
            if found < 0:
                break
            at = found + len(part)
        else:
            return True
    return False


def prompt(turns: Sequence[str], memory: Dict[str, List[str]], today: date) -> List[Dict[str, str]]:
    known = "\n".join(f"[{target}] {entry}" for target in ("user", "memory") for entry in memory.get(target, []))
    said = "\n".join(f"- {turn}" for turn in turns)
    system = (
        "You keep an assistant's long-term memory about the person it helps. From the person's own "
        "messages below, list durable facts about them that memory does not already hold.\n"
        "Keep only what a new assistant should still know next month: where they live, family, work, "
        "health they mention, lasting preferences about how they want to be helped, important names. "
        "Not tasks, questions, requests, what they are doing today, opinions about one reply, or "
        "anything about other people's private data beyond what the person shares about their own life.\n"
        "Write each fact as one short, self-contained sentence in the language the person uses, about "
        "the person in the third person. Use target \"user\" for facts about the person and \"memory\" "
        "only for standing instructions about how the assistant should work.\n"
        "For each fact give `evidence`: the person's exact words copied from one message (fragments "
        "joined by \"...\" are allowed). If a fact updates or contradicts an entry already in memory, "
        "put that entry's full text, exactly as listed, in `replaces`.\n"
        f"Today is {today.isoformat()}. If nothing qualifies, return an empty list. Answer with JSON "
        "only: {\"facts\": [{\"target\": \"user\", \"text\": \"...\", \"evidence\": \"...\", "
        "\"replaces\": null}]}"
    )
    user = f"Memory now:\n{known or '(empty)'}\n\nThe person's messages:\n{said}"
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def parse(reply: str) -> List[Dict[str, Any]]:
    text = reply or ""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return []
    try:
        data = json.loads(text[start:end + 1])
    except ValueError:
        return []
    facts = data.get("facts") if isinstance(data, dict) else None
    return [f for f in facts if isinstance(f, dict)] if isinstance(facts, list) else []


# Words that say something changed ("ahora vivo en…", "me he mudado", "ya no trabajo en…"): with
# them, a fact replaces what memory held; without them, a contradiction is asked, not assumed.
CHANGE = re.compile(
    r"\b(ahora|ya no|me he mudado|me mud[eé]|nos hemos mudado|he cambiado|cambi[eé]|desde (hace|ayer|el|la)|"
    r"nuev[oa]s?|actualmente|a partir de|now|no longer|moved|changed|since|currently|new)\b", re.IGNORECASE)
MAX_QUESTIONS = 5
QUESTION_DAYS = 21


def accepted(facts: Sequence[Dict[str, Any]], turns: Sequence[str],
             memory: Dict[str, List[str]], doubts: Optional[List[Dict[str, str]]] = None) -> List[Dict[str, Any]]:
    """The facts that pass every check, at most ``MAX_FACTS``. A fact that contradicts memory
    without the person saying it changed goes to ``doubts`` instead: Alice asks, never guesses."""
    known = {_plain(entry) for entries in memory.values() for entry in entries}
    keep: List[Dict[str, Any]] = []
    for fact in facts:
        target = str(fact.get("target") or "user")
        text = " ".join(str(fact.get("text") or "").split())
        replaces = fact.get("replaces")
        replaces = str(replaces) if isinstance(replaces, str) and replaces.strip() else None
        if target not in ("user", "memory") or not (8 <= len(text) <= MAX_FACT) or "§" in text:
            continue
        if not quoted(str(fact.get("evidence") or ""), turns):
            continue
        if _plain(text) in known:
            continue
        if replaces is not None:
            # The entry as it is on disk; one it cannot point to exactly is too unsure to act on.
            replaces = next((e for e in memory.get(target, []) if _plain(e) == _plain(replaces)), None)
            if replaces is None:
                continue
            if not CHANGE.search(str(fact.get("evidence") or "")):
                if doubts is not None:
                    doubts.append({"known": replaces, "said": text, "evidence": str(fact["evidence"]).strip()})
                continue
        known.add(_plain(text))
        keep.append({"target": target, "text": text, "evidence": str(fact["evidence"]).strip(),
                     "replaces": replaces})
        if len(keep) >= MAX_FACTS:
            break
    return keep


def review(turns: Sequence[str], keeper, ask: Callable[[List[Dict[str, str]]], str], *,
           session: str = "", profile: str = "", today: Optional[date] = None) -> List[Dict[str, Any]]:
    """One look: asks the model, keeps what passes, returns the changes made."""
    if not turns:
        return []
    memory = {target: keeper.files.entries(target) for target in ("user", "memory")}
    doubts: List[Dict[str, str]] = []
    facts = accepted(parse(ask(prompt(turns, memory, today or date.today()))), turns, memory, doubts)
    if doubts:
        remember_doubts(keeper, doubts)
    changes = []
    for fact in facts:
        change = keeper.learn(fact["target"], fact["text"], replaces=fact["replaces"],
                              evidence=fact["evidence"], session=session, profile=profile)
        if change:
            changes.append(change)
    return changes


# ── Contradictions to ask about ─────────────────────────────────────────────────

def remember_doubts(keeper, doubts: Sequence[Dict[str, str]], now: Optional[float] = None) -> None:
    import time as _time

    now = now or _time.time()
    kept = [q for q in keeper._read("questions.json", []) if isinstance(q, dict)]
    for doubt in doubts:
        if not any(_plain(q.get("known", "")) == _plain(doubt["known"]) and _plain(q.get("said", "")) == _plain(doubt["said"])
                   for q in kept):
            kept.append({**doubt, "at": now})
    keeper._write("questions.json", kept[-MAX_QUESTIONS:])


def open_doubts(keeper, now: Optional[float] = None) -> List[Dict[str, str]]:
    """Contradictions still worth asking: recent, and memory still says the old thing."""
    import time as _time

    now = now or _time.time()
    known = {_plain(e) for target in ("user", "memory") for e in keeper.files.entries(target)}
    questions = [q for q in keeper._read("questions.json", []) if isinstance(q, dict)]
    live = [q for q in questions
            if now - float(q.get("at") or 0) < QUESTION_DAYS * 86400 and _plain(q.get("known", "")) in known
            and _plain(q.get("said", "")) not in known]
    if len(live) != len(questions):
        keeper._write("questions.json", live)
    return live[-2:]


def doubts_prompt(doubts: Sequence[Dict[str, str]]) -> str:
    if not doubts:
        return ""
    lines = "\n".join(f"- Tu memoria dice «{d['known']}», pero dijo «{d['evidence']}»." for d in doubts)
    return ("## Algo no cuadra en lo que sabes de la persona\n" + lines + "\n"
            "Cuando venga al caso —no de golpe, una sola cosa y con naturalidad— pregúntaselo "
            "(«¿Te has mudado a Manresa?») y actualiza tu memoria con lo que diga. No lo des por hecho antes.")
