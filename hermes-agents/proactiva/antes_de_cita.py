#!/usr/bin/env python3
"""Las citas de Marcos que empiezan en torno a una hora, para la rutina «Antes de cada cita».

Hermes lo ejecuta cada 15 minutos en modo monitor: si lo que imprime no cambia,
no despierta al modelo. Por eso la salida es estable — título, hora y lugar,
nunca «empieza en N minutos» — y vacía cuando no hay ninguna cita en la ventana.
Lee la agenda que el iPhone envía a Hermes (`.alice/calendar.json`); solo lectura.

    python3 antes_de_cita.py
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, tzinfo
from pathlib import Path
from typing import List, Optional

HOME = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
# Una cita entra cuando empieza entre 45 y 75 minutos desde ahora: con una
# comprobación cada 15 minutos, cada cita se ve una vez y con margen.
EARLIEST = 45 * 60
LATEST = 75 * 60


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


def upcoming(home: Path, now: float) -> List[str]:
    try:
        data = json.loads((home / ".alice" / "calendar.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict) or not data.get("connected"):
        return []
    tz = zone(home)
    lines = []
    for event in data.get("events") or []:
        if event.get("all_day"):
            continue
        begins = stamp(event.get("start"))
        if begins is None or not (now + EARLIEST <= begins <= now + LATEST):
            continue
        at = datetime.fromtimestamp(begins, tz).strftime("%H:%M")
        where = f" · {event['location']}" if event.get("location") else ""
        lines.append((begins, f"- {at} {event.get('title', 'Cita')}{where}"))
    return [line for _, line in sorted(lines)]


def main() -> int:
    for line in upcoming(HOME, time.time()):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
