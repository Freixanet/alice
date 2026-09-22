#!/usr/bin/env python3
"""Los hechos del «Buenos días» de Alice, leídos de Hermes sin cambiar nada.

Hermes ejecuta este script antes de la rutina de la mañana y pone lo que
imprime en el prompt: lo que cada agente dijo en su chat desde anoche, las
rutinas que fallaron y las que tocan hoy. El modelo escribe el briefing a
partir de esto; aquí no se inventa ni se resume nada, solo se reúne.

Solo lectura: abre cada base de datos en modo ``ro``. No imprime mensajes
enteros, solo el arranque de la última respuesta de cada agente.

    python3 buenos_dias.py [--horas 16]
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import time
from contextlib import closing
from datetime import datetime, tzinfo
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HOME = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
ROUTINE_REPORT = '[Cronjob "'
SILENT = "[SILENT]"
PREVIEW = 180


def profiles(home: Path) -> List[Tuple[str, Path]]:
    """Every agent but Alice herself: her own chat is where this is going."""
    root = home / "profiles"
    if not root.is_dir():
        return []
    return sorted(
        (p.name, p) for p in root.iterdir()
        if (p / "state.db").is_file() and not internal(p)
    )


def internal(directory: Path) -> bool:
    """Profiles Alice keeps out of sight (`ui_meta.alice.internal`), like the evals sandbox."""
    try:
        text = (directory / "profile.yaml").read_text(encoding="utf-8")
    except OSError:
        return False
    return re.search(r"^\s*internal:\s*true\s*$", text, re.MULTILINE) is not None


def title(name: str, directory: Path) -> str:
    try:
        text = (directory / "profile.yaml").read_text(encoding="utf-8")
    except OSError:
        return name
    match = re.search(r"hermes-bots:\s*\n\s+title:\s*(.+)", text)
    return match.group(1).strip().strip("'\"") if match else name


def opening(text: str) -> str:
    """The first words of a reply, on one line, without markdown."""
    line = re.sub(r"\s+", " ", text)
    line = re.sub(r"^[#>*\-\s]+", "", line).replace("**", "").replace("`", "").strip()
    return line[:PREVIEW] + ("…" if len(line) > PREVIEW else "")


def news(db: Path, since: float) -> Optional[Dict[str, object]]:
    """What an agent said in its own chat since ``since``: how much, and the latest."""
    try:
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            rows = conn.execute(
                "SELECT m.role, m.content FROM messages m JOIN sessions s ON s.id = m.session_id "
                "WHERE s.title = 'Bot Chat' AND m.timestamp >= ? AND m.role IN ('user', 'assistant') "
                "ORDER BY m.id",
                (since,),
            ).fetchall()
    except sqlite3.Error:
        return None
    replies = []
    reports = 0
    for role, content in rows:
        text = (content or "").strip()
        if role == "user":
            if text.startswith(ROUTINE_REPORT):
                reports += 1
            continue
        if text and text != SILENT:
            replies.append(text)
    if not replies and not reports:
        return None
    return {"replies": len(replies), "reports": reports, "latest": opening(replies[-1]) if replies else ""}


def jobs(directory: Path) -> List[dict]:
    try:
        data = json.loads((directory / "cron" / "jobs.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    rows = data.get("jobs", data) if isinstance(data, dict) else data
    return list(rows.values()) if isinstance(rows, dict) else list(rows or [])


def stamp(value) -> Optional[float]:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


_DAYS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
_MONTHS = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
           "septiembre", "octubre", "noviembre", "diciembre"]


def zone(home: Path) -> Optional[tzinfo]:
    """Hermes' own timezone (`timezone:` in config.yaml): the Mac's can differ."""
    try:
        text = (home / "config.yaml").read_text(encoding="utf-8")
        match = re.search(r"^timezone:\s*['\"]?([\w/+-]+)", text, re.MULTILINE)
        if match:
            from zoneinfo import ZoneInfo
            return ZoneInfo(match.group(1))
    except Exception:
        pass
    return None


def calendar_today(home: Path, now: float, local) -> Optional[List[str]]:
    """Today's events from the calendar his iPhone sent (`.alice/calendar.json`).

    None when it is not connected: then the briefing says nothing about it.
    """
    try:
        data = json.loads((home / ".alice" / "calendar.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not data.get("connected"):
        return None
    today = local(now).date()
    rows = []
    for event in data.get("events") or []:
        begins, ends = stamp(event.get("start")), stamp(event.get("end"))
        if begins is None or ends is None:
            continue
        if not (local(begins).date() <= today <= local(ends - 1).date()):
            continue
        when = "todo el día" if event.get("all_day") else local(begins).strftime("%H:%M")
        where = f" · {event['location']}" if event.get("location") else ""
        rows.append((begins, f"- {when} {event.get('title', 'Ocupado')}{where}"))
    return [line for _, line in sorted(rows)]


def facts(home: Path, now: float, hours: float) -> str:
    since = now - hours * 3600
    tz = zone(home)

    def local(value: float) -> datetime:
        return datetime.fromtimestamp(value, tz)

    today = local(now).date()
    heard: List[str] = []
    failed: List[str] = []
    upcoming: List[str] = []
    everyone = [("default", home)] + profiles(home)
    for name, directory in everyone:
        who = "Alice" if name == "default" else title(name, directory)
        if name != "default":
            found = news(directory / "state.db", since)
            if found:
                parts = []
                if found["reports"]:
                    parts.append(f"{found['reports']} informe(s) de rutina")
                if found["replies"]:
                    parts.append(f"{found['replies']} respuesta(s)")
                line = f"- {who}: {', '.join(parts)}"
                if found["latest"]:
                    line += f". Lo último: «{found['latest']}»"
                heard.append(line)
        for job in jobs(directory):
            if job.get("enabled") is False or job.get("paused"):
                continue
            ran = stamp(job.get("last_run_at"))
            if ran and ran >= now - 24 * 3600 and job.get("last_status") not in (None, "ok"):
                error = opening(str(job.get("last_error") or ""))[:100]
                failed.append(f"- «{job.get('name', 'sin nombre')}» ({who})" + (f": {error}" if error else ""))
            upcoming_at = stamp(job.get("next_run_at"))
            if upcoming_at and upcoming_at > now and local(upcoming_at).date() == today:
                at = local(upcoming_at).strftime("%H:%M")
                upcoming.append(f"- {at} «{job.get('name', 'sin nombre')}» ({who})")

    agenda = calendar_today(home, now, local)

    moment = local(now)
    lines = [
        f"Fecha: {_DAYS[moment.weekday()]} {moment.day} de {_MONTHS[moment.month - 1]}, "
        f"{moment.strftime('%H:%M')}"
    ]
    lines.append(f"\nLo que dijeron tus agentes en sus chats en las últimas {int(hours)} h:")
    lines += heard or ["- Nada nuevo."]
    lines.append("\nRutinas que fallaron en las últimas 24 h:")
    lines += failed or ["- Ninguna."]
    if agenda is not None:
        lines.append("\nSu agenda de hoy (de su calendario):")
        lines += agenda or ["- Nada en el calendario."]
    lines.append("\nRutinas programadas para lo que queda de hoy:")
    lines += sorted(upcoming) or ["- Ninguna."]
    return "\n".join(lines)


def main(argv: List[str]) -> int:
    hours = 16.0
    if "--horas" in argv:
        hours = float(argv[argv.index("--horas") + 1])
    print(facts(HOME, time.time(), hours))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
