"""The person's calendar as their iPhone last sent it, for Alice to read.

Hermes has no calendar of its own; connecting Google's takes a Cloud project
and an OAuth client. The iPhone already holds every account the person uses
(iCloud, Google, Exchange), so Alice asks iOS for read access — one tap — and
sends a window of upcoming events here. Agents read it through the
``calendar_events`` tool, which always says where things stand:

* ``connected`` — events are here, as fresh as ``updated_at``.
* ``not_connected`` — never connected, or disconnected: Alice may offer it.
* ``declined`` — the person said "not now": Alice does not offer it again.

Read-only: nothing here creates or changes an event. Event notes are never
sent; titles, times, places and the calendar's name are.
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

MAX_EVENTS = 600
MAX_TEXT = 200


def path(home: Path) -> Path:
    return home / ".alice" / "calendar.json"


def read(home: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path(home).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write(home: Path, data: Dict[str, Any]) -> None:
    target = path(home)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(".calendar.json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(target)


def status(home: Path) -> Dict[str, Any]:
    data = read(home)
    if data.get("connected"):
        return {
            "status": "connected",
            "updated_at": data.get("updated_at"),
            "events": len(data.get("events") or []),
        }
    if data.get("declined_at"):
        return {"status": "declined", "declined_at": data.get("declined_at")}
    return {"status": "not_connected"}


def _clean(event: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    start, end = event.get("start"), event.get("end")
    if not isinstance(start, str) or not isinstance(end, str):
        return None
    try:
        datetime.fromisoformat(start.replace("Z", "+00:00"))
        datetime.fromisoformat(end.replace("Z", "+00:00"))
    except ValueError:
        return None
    cleaned = {
        "title": str(event.get("title") or "Busy")[:MAX_TEXT],
        "start": start,
        "end": end,
        "all_day": bool(event.get("all_day")),
    }
    for key in ("location", "calendar"):
        value = event.get(key)
        if isinstance(value, str) and value.strip():
            cleaned[key] = value.strip()[:MAX_TEXT]
    return cleaned


MAX_REMINDERS = 60


def _clean_reminder(item: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """A to-do still open: its title, when it is due (if ever), its list and priority. Never its notes."""
    title = str(item.get("title") or "").strip()[:MAX_TEXT]
    if not title:
        return None
    cleaned: Dict[str, Any] = {"title": title}
    due = item.get("due")
    if isinstance(due, str):
        try:
            datetime.fromisoformat(due.replace("Z", "+00:00"))
            cleaned["due"] = due
        except ValueError:
            pass
    if isinstance(item.get("list"), str) and item["list"].strip():
        cleaned["list"] = item["list"].strip()[:MAX_TEXT]
    try:
        priority = int(item.get("priority") or 0)
    except (TypeError, ValueError):
        priority = 0
    if priority in (1, 2, 3):
        cleaned["priority"] = priority
    return cleaned


def save(home: Path, events: List[Dict[str, Any]], window_start: str, window_end: str,
         now: Optional[float] = None, reminders: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
    """The phone's latest window. Connecting also lifts an earlier "not now".

    ``reminders``: the open to-dos due by tomorrow, overdue ones and urgent undated ones,
    sent by an app that can read Reminders; an older app sends none.
    """
    kept = [e for e in (_clean(item) for item in events[:MAX_EVENTS] if isinstance(item, dict)) if e]
    kept.sort(key=lambda e: e["start"])
    stamp = datetime.fromtimestamp(now or time.time(), timezone.utc).isoformat(timespec="seconds")
    data = {
        "connected": True,
        "updated_at": stamp,
        "window": {"start": window_start, "end": window_end},
        "events": kept,
    }
    if reminders is not None:
        data["reminders"] = [r for r in (_clean_reminder(item) for item in reminders[:MAX_REMINDERS]
                                         if isinstance(item, dict)) if r]
    _write(home, data)
    return {"ok": True, "events": len(kept), "reminders": len(data.get("reminders") or [])}


def decline(home: Path, now: Optional[float] = None) -> Dict[str, Any]:
    stamp = datetime.fromtimestamp(now or time.time(), timezone.utc).isoformat(timespec="seconds")
    _write(home, {"connected": False, "declined_at": stamp})
    return {"ok": True, "status": "declined"}


def disconnect(home: Path) -> Dict[str, Any]:
    """Forgets every event and goes back to never connected."""
    _write(home, {"connected": False})
    return {"ok": True, "status": "not_connected"}


def zone(home: Path):
    """Hermes' own timezone (``timezone:`` in config.yaml), or None for the Mac's."""
    import re

    try:
        text = (home / "config.yaml").read_text(encoding="utf-8")
        match = re.search(r"^timezone:\s*['\"]?([\w/+-]+)", text, re.MULTILINE)
        if match:
            from zoneinfo import ZoneInfo

            return ZoneInfo(match.group(1))
    except Exception:
        pass
    return None


def events(home: Path, days_ahead: float = 7, days_back: float = 0,
           now: Optional[datetime] = None, tz=None) -> Dict[str, Any]:
    """What the ``calendar_events`` tool returns.

    The window starts at midnight of the person's day, not at this minute: asked what they
    had today, an agent read from now on and missed this morning's appointments.
    """
    found = status(home)
    if found["status"] != "connected":
        return found
    now = now or datetime.now(timezone.utc)
    local = now.astimezone(tz) if tz else now.astimezone()
    midnight = local.replace(hour=0, minute=0, second=0, microsecond=0)
    start = midnight - timedelta(days=max(0.0, float(days_back)))
    end = now + timedelta(days=max(0.0, min(float(days_ahead), 60.0)))
    chosen = []
    for event in read(home).get("events") or []:
        try:
            begins = datetime.fromisoformat(event["start"].replace("Z", "+00:00"))
            ends = datetime.fromisoformat(event["end"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if begins.tzinfo is None:
            begins = begins.replace(tzinfo=timezone.utc)
        if ends.tzinfo is None:
            ends = ends.replace(tzinfo=timezone.utc)
        if ends >= start and begins <= end:
            chosen.append(event)
    return {**found, "from": start.isoformat(timespec="minutes"),
            "to": end.isoformat(timespec="minutes"), "events": chosen}
