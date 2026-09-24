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
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.request
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


def reminders_due(home: Path, now: float, local) -> Optional[List[str]]:
    """Open to-dos his iPhone sent with the calendar: overdue, today, tomorrow, urgent undated.

    None when the app has not sent any (Reminders not allowed, or an older app).
    """
    try:
        data = json.loads((home / ".alice" / "calendar.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or "reminders" not in data:
        return None
    today = local(now).date()
    rows = []
    for item in data.get("reminders") or []:
        due = stamp(item.get("due"))
        mark = " (!!!)" if item.get("priority") == 3 else ""
        where = f" · {item['list']}" if item.get("list") else ""
        if due is None:
            rows.append((3, 0.0, f"- sin fecha{mark}: {item.get('title', '')}{where}"))
            continue
        day = local(due).date()
        if day < today:
            rows.append((0, due, f"- VENCIDO desde el {day.day}/{day.month}{mark}: {item.get('title', '')}{where}"))
        elif day == today:
            rows.append((1, due, f"- hoy {local(due).strftime('%H:%M')}{mark}: {item.get('title', '')}{where}"))
        else:
            rows.append((2, due, f"- mañana{mark}: {item.get('title', '')}{where}"))
    return [line for _, _, line in sorted(rows)]


def _health_module(home: Path):
    """Alice's plugin reads Health; the briefing reuses it rather than a second copy of the maths."""
    import importlib.util

    path = home / "plugins" / "alice" / "health.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("alice_health_briefing", path)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception:
        return None
    return module


def health_facts(home: Path, now: float, local) -> Optional[Dict[str, List[str]]]:
    """What is clearly off in last night's sleep and recovery, one pattern, and on Mondays the week."""
    module = _health_module(home)
    if module is None or not module.read(home).get("connected"):
        return None
    today = local(now).date()
    facts = {"notable": module.notable(home, today),
             "patterns": [p["text"] for p in module.patterns(home, today=today)[:1]]}
    if today.weekday() == 0:
        facts["week"] = module.week(home, today)
    return facts


def open_goals(home: Path, local) -> List[str]:
    """Active goals and the next step of each (`.alice/goals.json`, kept by the goals tool)."""
    try:
        data = json.loads((home / ".alice" / "goals.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    rows = []
    for goal in (data.get("goals") if isinstance(data, dict) else None) or []:
        if goal.get("status") != "active":
            continue
        steps = goal.get("steps") or []
        nxt = next((st.get("text") or st.get("title") for st in steps if st.get("status") != "done"), None)
        due = f" (para el {goal['due']})" if goal.get("due") else ""
        line = f"- {goal.get('title', 'Objetivo')}{due}"
        measure = goal.get("measure")
        module = _health_module(home) if measure else None
        reading = module.goal_progress(home, measure.get("metric", ""), measure.get("target", 0),
                                       measure.get("direction", "at_least"), measure.get("window_days", 7)) if module else None
        if reading:
            line += f" → media {reading['average']}, {reading['percent']} %" + (" (cumplido)" if reading["met"] else "")
        elif nxt:
            line += f" → siguiente paso: {nxt}"
        rows.append(line)
    return rows[:6]


def _run(argv: List[str]) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


def system_health(home: Path, now: float) -> List[str]:
    """This Mac and Hermes: free disk, memory pressure, uptime, services. Only numbers."""
    lines = []
    try:
        disk = shutil.disk_usage(str(Path.home()))
        free = disk.free / disk.total * 100
        lines.append(f"- Disco: {disk.free / 1e9:.0f} GB libres ({free:.0f} %)" + (" — POCO ESPACIO" if free < 10 else ""))
    except OSError:
        pass
    memory = re.search(r"free percentage:\s*(\d+)%", _run(["memory_pressure", "-Q"]))
    if memory:
        pct = int(memory.group(1))
        lines.append(f"- Memoria libre: {pct} %" + (" — PRESIÓN ALTA" if pct < 15 else ""))
    battery = re.search(r"(\d+)%;\s*([\w ]+);", _run(["pmset", "-g", "batt"]))
    if battery:
        pct, state = int(battery.group(1)), battery.group(2).strip()
        plugged = "cargando" if state in ("charging", "charged", "finishing charge") else "sin enchufar"
        lines.append(f"- Batería del Mac: {pct} % ({plugged})" + (" — BAJA" if pct < 20 and plugged != "cargando" else ""))
    boot = re.search(r"sec = (\d+)", _run(["sysctl", "-n", "kern.boottime"]))
    if boot:
        days = (now - int(boot.group(1))) / 86400
        lines.append(f"- Encendido desde hace {days:.1f} días")
    listed = _run(["launchctl", "list"])
    for label, name in (("ai.hermes.gateway", "Hermes (mensajería)"), ("ai.hermes.dashboard", "Hermes (app del iPhone)")):
        row = next((l.split() for l in listed.splitlines() if l.endswith("\t" + label) or l.split()[-1:] == [label]), None)
        if row is None:
            lines.append(f"- {name}: NO CARGADO")
        elif row[0] == "-":
            lines.append(f"- {name}: PARADO (último código {row[1]})")
        else:
            lines.append(f"- {name}: en marcha")
    return lines


def sites(home: Path) -> List[str]:
    """The person's own websites (`.alice/sitios.json`: a list of URLs), checked once each."""
    try:
        urls = json.loads((home / ".alice" / "sitios.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    rows = []
    for url in [u for u in urls if isinstance(u, str) and u.startswith(("https://", "http://"))][:8]:
        started = time.time()
        try:
            request = urllib.request.Request(url, method="GET", headers={"User-Agent": "Alice-health/1"})
            with urllib.request.urlopen(request, timeout=8) as response:
                code = response.status
        except urllib.error.HTTPError as error:
            code = error.code
        except Exception as error:
            rows.append(f"- {url}: CAÍDO ({type(error).__name__})")
            continue
        took = time.time() - started
        state = "bien" if code < 400 else f"ERROR {code}"
        rows.append(f"- {url}: {state} ({took:.1f} s)" + (" — LENTO" if took > 4 and code < 400 else ""))
    return rows


def overnight_errors(home: Path, since: float) -> List[str]:
    """Errors Hermes logged since last night, counted by where they came from. No message text."""
    counts: Dict[str, int] = {}
    pattern = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ (ERROR|CRITICAL) (?:\[[^\]]*\] )?([\w.]+)")
    for name in ("errors.log", "errors.log.1"):
        try:
            text = (home / "logs" / name).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            match = pattern.match(line)
            if not match:
                continue
            try:
                when = datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S").timestamp()
            except ValueError:
                continue
            if when >= since:
                counts[match.group(3)] = counts.get(match.group(3), 0) + 1
    top = sorted(counts.items(), key=lambda kv: -kv[1])[:5]
    return [f"- {source}: {count} error(es)" for source, count in top]


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
    todo = reminders_due(home, now, local)
    goals = open_goals(home, local)
    health = system_health(home, now)
    web = sites(home)
    errors = overnight_errors(home, since)
    body = health_facts(home, now, local)

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
    if todo is not None:
        lines.append("\nSus recordatorios abiertos (vencidos, hoy, mañana, urgentes sin fecha):")
        lines += todo or ["- Ninguno pendiente."]
    if goals:
        lines.append("\nSus objetivos activos:")
        lines += goals
    if body is not None:
        lines.append("\nSu salud (app Salud del iPhone y su pulsera; solo lo que se sale de su normal):")
        lines += body["notable"] or ["- Nada fuera de lo normal."]
        if body["patterns"]:
            lines.append("Un patrón que se repite en sus datos:")
            lines += [f"- {p}" for p in body["patterns"]]
        if "week" in body:
            lines.append("Su semana (últimos 7 días frente a los 7 anteriores):")
            lines += body["week"] or ["- Sin datos suficientes."]
    lines.append("\nRutinas programadas para lo que queda de hoy:")
    lines += sorted(upcoming) or ["- Ninguna."]
    lines.append("\nEstado del sistema (su Mac y Hermes):")
    lines += health or ["- No se pudo leer."]
    if web:
        lines.append("\nSus webs:")
        lines += web
    lines.append(f"\nErrores registrados por Hermes en las últimas {int(hours)} h:")
    lines += errors or ["- Ninguno."]
    return "\n".join(lines)


def main(argv: List[str]) -> int:
    hours = 16.0
    if "--horas" in argv:
        hours = float(argv[argv.index("--horas") + 1])
    print(facts(HOME, time.time(), hours))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
