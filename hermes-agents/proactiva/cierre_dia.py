#!/usr/bin/env python3
"""Los hechos del «Cierre del día» de Alice, leídos de Hermes sin cambiar nada.

Lo que Marc escribió hoy en sus conversaciones con Alice — de donde salen las
promesas y los cabos sueltos («te lo mando mañana», «tengo que llamar a…») — y
su agenda de mañana, si conectó el calendario. El modelo decide qué merece
contarse; aquí solo se reúne, recortado.

Solo lectura: abre la base de datos en modo ``ro``.

    python3 cierre_dia.py
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import time
from contextlib import closing
from datetime import datetime, timedelta, tzinfo
from pathlib import Path
from typing import List, Optional

HOME = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
MAX_MESSAGES = 40
MAX_CHARS = 300
# What a routine hands a chat is not something Marc wrote.
NOT_HIS = ('[Cronjob "', "[IMPORTANT: Background process", "Message from 🤖")


def zone(home: Path) -> Optional[tzinfo]:
    try:
        text = (home / "config.yaml").read_text(encoding="utf-8")
        match = re.search(r"^timezone:\s*['\"]?([\w/+-]+)", text, re.MULTILINE)
        if match:
            from zoneinfo import ZoneInfo
            return ZoneInfo(match.group(1))
    except Exception:
        pass
    return None


def stamp(value) -> Optional[float]:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def said_today(home: Path, now: float, tz) -> List[str]:
    """What Marc wrote to Alice today, oldest first, each trimmed."""
    midnight = datetime.fromtimestamp(now, tz).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    try:
        with closing(sqlite3.connect(f"file:{home / 'state.db'}?mode=ro", uri=True)) as conn:
            rows = conn.execute(
                "SELECT m.content FROM messages m JOIN sessions s ON s.id = m.session_id "
                "WHERE m.role = 'user' AND m.timestamp >= ? AND s.source != 'cron' ORDER BY m.id",
                (midnight,),
            ).fetchall()
    except sqlite3.Error:
        return []
    lines, seen = [], set()
    for (content,) in rows:
        text = re.sub(r"\s+", " ", (content or "")).strip()
        # The same thing sent twice is one thing to follow up.
        if not text or text.startswith(NOT_HIS) or text.lower() in seen:
            continue
        seen.add(text.lower())
        lines.append("- " + (text[:MAX_CHARS] + ("…" if len(text) > MAX_CHARS else "")))
    return lines[-MAX_MESSAGES:]


def tomorrow(home: Path, now: float, tz) -> Optional[List[str]]:
    try:
        data = json.loads((home / ".alice" / "calendar.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not data.get("connected"):
        return None
    day = (datetime.fromtimestamp(now, tz) + timedelta(days=1)).date()
    rows = []
    for event in data.get("events") or []:
        begins = stamp(event.get("start"))
        if begins is None or datetime.fromtimestamp(begins, tz).date() != day:
            continue
        when = "todo el día" if event.get("all_day") else datetime.fromtimestamp(begins, tz).strftime("%H:%M")
        where = f" · {event['location']}" if event.get("location") else ""
        rows.append((begins, f"- {when} {event.get('title', 'Ocupado')}{where}"))
    return [line for _, line in sorted(rows)]


def facts(home: Path, now: float) -> str:
    tz = zone(home)
    lines = ["Lo que Marc te escribió hoy:"]
    lines += said_today(home, now, tz) or ["- Nada."]
    agenda = tomorrow(home, now, tz)
    if agenda is not None:
        lines.append("\nSu agenda de mañana:")
        lines += agenda or ["- Nada en el calendario."]
    return "\n".join(lines)


def main() -> int:
    print(facts(HOME, time.time()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
