"""Curated memory that keeps itself tidy, remembers where each entry came from, and can
undo every change it makes.

Hermes keeps a profile's curated memory in two plain files, ``memories/MEMORY.md`` (the
agent's notes) and ``memories/USER.md`` (about the person): entries separated by ``§``,
with no date, no origin and no id. This module leaves those files exactly as Hermes writes
them and keeps its own record beside them, in ``<profile home>/.alice/memory/``:

* **Where an entry came from** (``entries.json``), keyed by a hash of its text: when it was
  first seen and who wrote it — an agent (with its session and profile), the person from
  the Alice app, or someone editing the file by hand. Entries that were already there the
  first time Alice looked are ``legacy``: they keep working and simply have no history.
* **Every change it makes** (``changes.json``), with the full text of what it removed, so
  any change can be reverted and nothing is ever deleted without a trace.
* **Whether it may act** (``settings.json``). By default it only *proposes*; applying is a
  setting.

Cleanup is deliberately conservative and touches only three things:

1. **Clear duplicates** — the same entry again, ignoring case, spacing and final
   punctuation. The oldest copy stays.
2. **Dates that have passed** — an entry about a dated event (a flight, an appointment,
   a deadline…) whose every explicit date is more than a day behind us.
3. **"Ya no…"** — a newer entry saying something is no longer true, and an older entry
   saying it is: the older one goes; the "ya no" stays.

Anything doubtful is left alone. Entries edited by hand or by the person from the app are
never touched by any rule. Legacy entries (no metadata) take part only in exact
duplicates and in dates that include the year, and every such change can be reverted.

The memory files are read and written only through Hermes' own ``MemoryStore`` (its lock,
its atomic writes, its size limit), passed in as ``files``: see ``HermesFiles``.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
import unicodedata
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

DIR = Path(".alice") / "memory"
TARGETS = ("memory", "user")
# Who wrote an entry. Never touched by cleanup: the person's own words.
PROTECTED = frozenset({"hand", "person"})
SOURCES = frozenset({"agent", "person", "hand", "legacy", "cleanup", "learned"})
MAX_CHANGES = 500


def entry_id(text: str) -> str:
    return hashlib.sha256(text.strip().encode("utf-8")).hexdigest()[:16]


def normalized(text: str) -> str:
    folded = unicodedata.normalize("NFKC", text or "").casefold()
    return " ".join(folded.split()).rstrip(" .!;,:")


# ── The memory files, through Hermes ─────────────────────────────────────────────


class HermesFiles:
    """Hermes' ``MemoryStore`` for the profile whose home is current."""

    def __init__(self, store=None):
        if store is None:
            from tools.memory_tool import load_on_disk_store

            store = load_on_disk_store()
        self.store = store

    def entries(self, target: str) -> List[str]:
        self.store.load_from_disk()
        return list(self.store._entries_for(target))

    def remove(self, target: str, text: str) -> Optional[str]:
        result = self.store.remove(target, text)
        return None if result.get("success") else str(result.get("error") or "Memory write failed")

    def add(self, target: str, text: str) -> Optional[str]:
        result = self.store.add(target, text)
        return None if result.get("success") else str(result.get("error") or "Memory write failed")

    def replace(self, target: str, old: str, new: str) -> Optional[str]:
        # ``old`` is always a whole entry: Hermes replaces the entry that contains it.
        result = self.store.replace(target, old, new)
        return None if result.get("success") else str(result.get("error") or "Memory write failed")


# ── Dates ────────────────────────────────────────────────────────────────────────

_MONTHS = {
    "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6, "julio": 7, "agosto": 8,
    "septiembre": 9, "setiembre": 9, "octubre": 10, "noviembre": 11, "diciembre": 12,
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
}
_MONTH = "|".join(sorted(_MONTHS, key=len, reverse=True))
_ISO = re.compile(r"\b(20\d\d)-(\d{1,2})-(\d{1,2})\b")
_SLASH = re.compile(r"\b(\d{1,2})[/.-](\d{1,2})[/.-](20\d\d)\b")
_DAY_MONTH = re.compile(rf"\b(\d{{1,2}})\s+de\s+({_MONTH})(?:\s+(?:de|del)\s+(20\d\d))?\b")
_MONTH_DAY = re.compile(rf"\b({_MONTH})\s+(\d{{1,2}})(?:st|nd|rd|th)?(?:,?\s+(20\d\d))?\b")
# An entry must be about something that happens on a day, not a fact with a date in it
# ("nació el 3 de mayo de 1990" is not something that expires).
_EVENT = re.compile(
    r"\b(cita|reuni[oó]n|viaje|vuelo|evento|entrevista|examen|plazo|entrega|vence|concierto|boda|"
    r"cumplea[ñn]os de|visita|reserva|appointment|meeting|flight|trip|deadline|due|interview|exam|"
    r"event|booking|reservation|tiene que|tengo que|hay que|debe)\b")


def _dates(text: str, year_hint: Optional[int]) -> Tuple[List[date], bool]:
    """Every explicit date in ``text``, and whether each one said its year."""
    plain = normalized(text)
    found: List[date] = []
    all_years = True

    def add(y, m, d, had_year):
        nonlocal all_years
        try:
            found.append(date(int(y), int(m), int(d)))
            all_years = all_years and had_year
        except ValueError:
            pass

    for y, m, d in _ISO.findall(plain):
        add(y, m, d, True)
    for d, m, y in _SLASH.findall(plain):
        add(y, m, d, True)
    for d, month, y in _DAY_MONTH.findall(plain):
        if y or year_hint:
            add(y or year_hint, _MONTHS[month], d, bool(y))
    for month, d, y in _MONTH_DAY.findall(plain):
        if y or year_hint:
            add(y or year_hint, _MONTHS[month], d, bool(y))
    return found, all_years


# ── "Ya no…" ─────────────────────────────────────────────────────────────────────

_NEGATION = re.compile(r"\b(ya no|no longer|dej[oó] de|ha dejado de|ya no es|already not|not anymore|"
                       r"ya no lo|ya no la)\b")
_STOP = frozenset((
    "el la los las un una unos unas de del al a en y o que es son por para con sin su sus se lo le les "
    "me mi mis tu tus muy mas más ya no ha he han the a an of to in on and or is are was were for with "
    "his her their its be has have had not longer anymore dejó dejo ha dejado marcos usuario user"
).split())


def _words(text: str) -> set:
    return {w for w in re.findall(r"[\wáéíóúüñ]+", normalized(_NEGATION.sub(" ", normalized(text))))
            if w not in _STOP and len(w) > 2}


def _similar(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


# ── The keeper ───────────────────────────────────────────────────────────────────


class Keeper:
    """The record for one profile, whose home is ``home``."""

    def __init__(self, home: Path, files, now: Callable[[], float] = time.time):
        self.dir = Path(home) / DIR
        self.files = files
        self.now = now

    # storage

    def _read(self, name: str, default):
        try:
            return json.loads((self.dir / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return default

    def _write(self, name: str, data) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        path = self.dir / name
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(data, indent=1, ensure_ascii=False), encoding="utf-8")
        os.replace(temp, path)

    def _meta(self) -> Dict[str, Any]:
        meta = self._read("entries.json", {})
        if not isinstance(meta, dict):
            meta = {}
        meta.setdefault("entries", {})
        meta.setdefault("initialized", {})
        return meta

    def settings(self) -> Dict[str, Any]:
        data = self._read("settings.json", {})
        data = data if isinstance(data, dict) else {}
        # Cleanup only proposes until turned on; learning what the person said is on.
        return {"apply": bool(data.get("apply")), "learn": data.get("learn") is not False}

    def _set(self, **values) -> Dict[str, Any]:
        data = self._read("settings.json", {})
        data = data if isinstance(data, dict) else {}
        data.update({k: bool(v) for k, v in values.items()}, changed_at=self.now())
        self._write("settings.json", data)
        return self.settings()

    def set_apply(self, apply: bool) -> Dict[str, Any]:
        return self._set(apply=apply)

    def set_learn(self, learn: bool) -> Dict[str, Any]:
        return self._set(learn=learn)

    def changes(self, limit: int = 100) -> List[Dict[str, Any]]:
        rows = self._read("changes.json", [])
        rows = rows if isinstance(rows, list) else []
        return list(reversed(rows[-limit:]))

    # origins

    def record(self, target: str, text: str, source: str, *, session: str = "", profile: str = "",
               at: Optional[float] = None) -> None:
        """Who wrote ``text`` into ``target``: called as it is written."""
        text = (text or "").strip()
        if not text or target not in TARGETS or source not in SOURCES:
            return
        meta = self._meta()
        key = f"{target}:{entry_id(text)}"
        current = meta["entries"].get(key) or {}
        # The person's word outranks an agent's: an entry they confirmed stays theirs.
        if current.get("source") in PROTECTED and source not in PROTECTED:
            return
        meta["entries"][key] = {"target": target, "source": source, "session": session or None,
                                "profile": profile or None, "created_at": at or self.now(),
                                "first_seen": current.get("first_seen") or at or self.now()}
        self._write("entries.json", meta)

    def scan(self, target: str) -> List[Dict[str, Any]]:
        """The current entries, each with what is known of it.

        The first look at a target marks what is there as ``legacy``. After that, an entry
        nobody recorded writing appeared outside Hermes' tools and the app: it was written
        or edited by hand, and is never touched.
        """
        entries = self.files.entries(target)
        meta = self._meta()
        known = meta["entries"]
        first_look = target not in meta["initialized"]
        changed = first_look
        rows = []
        for index, text in enumerate(entries):
            key = f"{target}:{entry_id(text)}"
            info = known.get(key)
            if info is None:
                info = {"target": target, "source": "legacy" if first_look else "hand", "session": None,
                        "profile": None, "created_at": None, "first_seen": self.now()}
                known[key] = info
                changed = True
            rows.append({"id": entry_id(text), "text": text, "index": index, **info})
        if first_look:
            meta["initialized"][target] = self.now()
        if changed:
            self._write("entries.json", meta)
        return rows

    def origin(self, target: str, text: Optional[str] = None, entry: Optional[str] = None) -> Dict[str, Any]:
        """Why Alice knows this: who wrote it, when, and in which conversation."""
        wanted = entry or (entry_id(text) if text else "")
        for row in self.scan(target):
            if row["id"] == wanted:
                return {"id": row["id"], "target": target, "source": row["source"], "session": row["session"],
                        "profile": row["profile"], "created_at": row["created_at"],
                        "first_seen": row["first_seen"], "known": row["source"] not in ("legacy",)}
        raise KeyError("That entry is not in memory.")

    # cleanup

    def propose(self, target: str, today: Optional[date] = None) -> List[Dict[str, Any]]:
        rows = self.scan(target)
        today = today or datetime.fromtimestamp(self.now()).date()
        declined = set(self._read("declined.json", []))
        proposals: List[Dict[str, Any]] = []
        taken: set = set()

        def age(row) -> float:
            return row.get("created_at") or row.get("first_seen") or 0

        def propose(kind: str, remove: List[Dict[str, Any]], keep: Optional[Dict[str, Any]], reason: str):
            ids = sorted(r["id"] for r in remove)
            pid = hashlib.sha256(f"{target}|{kind}|{','.join(ids)}".encode()).hexdigest()[:12]
            if pid in declined or any(i in taken for i in ids):
                return
            taken.update(ids)
            proposals.append({"id": pid, "kind": kind, "target": target, "reason": reason,
                              "remove": [{"id": r["id"], "text": r["text"], "source": r["source"]} for r in remove],
                              "keep": {"id": keep["id"], "text": keep["text"]} if keep else None})

        # 1. Clear duplicates.
        groups: Dict[str, List[Dict[str, Any]]] = {}
        for row in rows:
            groups.setdefault(normalized(row["text"]), []).append(row)
        for copies in groups.values():
            if len(copies) < 2:
                continue
            copies.sort(key=lambda r: (r["source"] not in PROTECTED, age(r)))
            keep, rest = copies[0], [r for r in copies[1:] if r["source"] not in PROTECTED]
            if rest:
                propose("duplicate", rest, keep, "La misma entrada estaba repetida.")

        # 2. Dated events that have passed.
        for row in rows:
            if row["source"] in PROTECTED or row["id"] in taken or not _EVENT.search(normalized(row["text"])):
                continue
            created = row.get("created_at")
            hint = datetime.fromtimestamp(created).year if created else None
            dates, with_years = _dates(row["text"], hint)
            if not dates or (row["source"] == "legacy" and not with_years):
                continue
            if max(dates) < today - timedelta(days=1):
                propose("expired", [row], None,
                        f"Hablaba de una fecha que ya pasó ({max(dates).isoformat()}).")

        # 3. A newer "ya no…" against an older entry saying the opposite.
        for newer in rows:
            if not _NEGATION.search(normalized(newer["text"])):
                continue
            words = _words(newer["text"])
            for older in rows:
                if older is newer or older["source"] in PROTECTED or older["id"] in taken:
                    continue
                if _NEGATION.search(normalized(older["text"])):
                    continue
                # Newer by its date, or — undated — by its place: Hermes appends.
                if (age(older), older["index"]) > (age(newer), newer["index"]):
                    continue
                if _similar(words, _words(older["text"])) >= 0.6:
                    propose("contradiction", [older], newer,
                            "Una entrada más reciente dice que ya no es así.")
        return proposals

    def run(self, targets=TARGETS, apply: Optional[bool] = None, today: Optional[date] = None) -> Dict[str, Any]:
        """Proposes, and applies when the setting (or ``apply``) says so."""
        apply = self.settings()["apply"] if apply is None else apply
        proposals = [p for target in targets for p in self.propose(target, today)]
        applied = [self._apply(p) for p in proposals] if apply else []
        return {"apply": apply, "proposals": proposals if not apply else [],
                "applied": [c for c in applied if c]}

    def _apply(self, proposal: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        target = proposal["target"]
        meta = self._meta()
        removed = []
        for item in proposal["remove"]:
            error = self.files.remove(target, item["text"])
            if error:
                break
            key = f"{target}:{item['id']}"
            removed.append({"text": item["text"], "meta": meta["entries"].get(key)})
        if not removed:
            return None
        change = {"id": proposal["id"], "at": self.now(), "kind": proposal["kind"], "target": target,
                  "reason": proposal["reason"], "removed": removed, "kept": proposal.get("keep"),
                  "reverted_at": None}
        self._log(change)
        return change

    def _log(self, change: Dict[str, Any]) -> None:
        rows = self._read("changes.json", [])
        rows = (rows if isinstance(rows, list) else []) + [change]
        self._write("changes.json", rows[-MAX_CHANGES:])

    def learn(self, target: str, text: str, *, replaces: Optional[str] = None, evidence: str = "",
              session: str = "", profile: str = "") -> Optional[Dict[str, Any]]:
        """Keeps a fact the person stated in a conversation (``memory_review``), replacing
        the entry it updates unless the person wrote that one themselves."""
        text = (text or "").strip()
        if target not in TARGETS or not text:
            return None
        rows = {row["text"]: row for row in self.scan(target)}
        if any(normalized(t) == normalized(text) for t in rows):
            return None
        old = rows.get(replaces) if replaces else None
        if replaces and (old is None or old["source"] in PROTECTED):
            return None
        error = self.files.replace(target, old["text"], text) if old else self.files.add(target, text)
        if error:
            return None
        meta = self._meta()
        removed = [{"text": old["text"], "meta": meta["entries"].get(f"{target}:{old['id']}")}] if old else []
        self.record(target, text, "learned", session=session, profile=profile)
        change = {"id": hashlib.sha256(f"{target}|learned|{entry_id(text)}|{self.now()}".encode()).hexdigest()[:12],
                  "at": self.now(), "kind": "learned", "target": target,
                  "reason": "Lo dijiste en una conversación.", "removed": removed,
                  "added": {"id": entry_id(text), "text": text, "evidence": evidence},
                  "session": session or None, "reverted_at": None}
        self._log(change)
        return change

    def revert(self, change_id: str) -> Dict[str, Any]:
        """Puts back what a change removed, with its original origin."""
        rows = self._read("changes.json", [])
        rows = rows if isinstance(rows, list) else []
        change = next((c for c in rows if c.get("id") == change_id), None)
        if change is None:
            raise KeyError("That change does not exist.")
        if change.get("reverted_at"):
            return change
        target = change["target"]
        added = change.get("added")
        if added:
            error = self.files.remove(target, added["text"])
            if error and added["text"] in self.files.entries(target):
                raise RuntimeError(error)
        meta = self._meta()
        for item in change["removed"]:
            error = self.files.add(target, item["text"])
            if error:
                raise RuntimeError(error)
            if item.get("meta"):
                meta["entries"][f"{target}:{entry_id(item['text'])}"] = item["meta"]
        self._write("entries.json", meta)
        change["reverted_at"] = self.now()
        self._write("changes.json", rows)
        # Put back by the person: the same cleanup is never proposed again.
        declined = set(self._read("declined.json", []))
        declined.add(change_id)
        self._write("declined.json", sorted(declined))
        return change
