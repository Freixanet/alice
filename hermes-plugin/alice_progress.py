"""Is Alice getting better? A weekly measure from what Hermes already records.

Read-only, from the installation's ``state.db`` (never message text in the output, only counts):

* **Tasks of several steps** (the ``finish_task`` goals): how many ended done, how many stopped
  to ask the person (paused with a real reason), and how many ran out of turns — this week
  against the week before.
* **Corrections**: the share of the person's messages that correct Alice ("no, te pedí…"),
  found with the same patterns as ``lessons.py``. Fewer corrections is the plainest sign she
  understands better.
* **Lessons kept**: what she learned from corrections and skills, from the logs the plugin keeps.

Shown in Monday's briefing, next to "Tu semana".
"""
from __future__ import annotations

import json
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from typing import Callable, Dict, List, Optional

WEEK = 7 * 86400


def _window(now: float, weeks_back: int):
    end = now - weeks_back * WEEK
    return end - WEEK, end


def tasks(db: Path, start: float, end: float) -> Dict[str, int]:
    counts = {"done": 0, "asked": 0, "exhausted": 0, "open": 0}
    try:
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            rows = conn.execute("SELECT value FROM state_meta WHERE key LIKE 'goal:%'").fetchall()
    except sqlite3.Error:
        return counts
    for (raw,) in rows:
        try:
            goal = json.loads(raw)
        except (TypeError, ValueError):
            continue
        created = float(goal.get("created_at") or 0)
        if not start <= created < end:
            continue
        status = goal.get("status")
        if status == "done":
            counts["done"] += 1
        elif status == "paused" and int(goal.get("turns_used") or 0) >= int(goal.get("max_turns") or 99):
            counts["exhausted"] += 1
        elif status == "paused":
            counts["asked"] += 1
        else:
            counts["open"] += 1
    return counts


def corrections(db: Path, start: float, end: float, is_correction: Callable[[str], bool]) -> Dict[str, int]:
    said = corrected = 0
    try:
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            rows = conn.execute(
                "SELECT m.content FROM messages m JOIN sessions s ON s.id = m.session_id "
                "WHERE m.role = 'user' AND m.timestamp >= ? AND m.timestamp < ? "
                "AND COALESCE(s.source, '') NOT IN ('cron')", (start, end)).fetchall()
    except sqlite3.Error:
        return {"said": 0, "corrected": 0}
    for (content,) in rows:
        text = content if isinstance(content, str) else ""
        if not text.strip() or text.startswith(("[Continuing toward", "[Alice app]", "[Aviso por ubicación]")):
            continue
        said += 1
        if is_correction(text):
            corrected += 1
    return {"said": said, "corrected": corrected}


def learned(home: Path, start: float, end: float) -> int:
    count = 0
    try:
        for line in (home / ".alice" / "learned.jsonl").read_text(encoding="utf-8").splitlines():
            entry = json.loads(line)
            if "learned" in entry and start <= float(entry.get("at") or 0) < end:
                count += 1
    except (OSError, ValueError):
        pass
    return count


def week_lines(home: Path, is_correction: Callable[[str], bool], now: Optional[float] = None) -> List[str]:
    """Lines for Monday's briefing; empty when there is nothing to compare yet."""
    now = now or time.time()
    db = home / "state.db"
    this, last = _window(now, 0), _window(now, 1)
    lines = []
    t_now, t_last = tasks(db, *this), tasks(db, *last)
    total = sum(t_now.values())
    if total:
        line = (f"- Tareas de varios pasos: {t_now['done']} terminadas de {total}"
                f" ({t_now['asked']} pararon para preguntarte, {t_now['exhausted']} se quedaron sin intentos)")
        last_total = sum(t_last.values())
        if last_total:
            line += f"; la semana anterior, {t_last['done']} de {last_total}"
        lines.append(line)
    c_now, c_last = corrections(db, *this, is_correction), corrections(db, *last, is_correction)
    if c_now["said"] >= 10:
        rate = c_now["corrected"] / c_now["said"] * 100
        line = f"- Correcciones tuyas: {c_now['corrected']} de {c_now['said']} mensajes ({rate:.0f} %)"
        if c_last["said"] >= 10:
            line += f"; la semana anterior, {c_last['corrected'] / c_last['said'] * 100:.0f} %"
        lines.append(line)
    kept = learned(home, *this)
    if kept:
        lines.append(f"- Aprendizajes guardados esta semana: {kept}")
    return lines
