"""Place triggers: something to do when the person arrives at or leaves a place.

"Cuando llegue al súper, recuérdame el aceite", "cuando salga del trabajo, avisa en casa".
An agent adds the trigger with the ``place_trigger`` tool (a place in words, or coordinates);
the iPhone reads the list (``GET /api/plugins/alice/places``), finds each place on the map
near the person, watches it with iOS region monitoring — which costs no battery and works
with the app closed — and reports back when they arrive or leave
(``POST /places/{id}/event``). The event wakes the agent that owns the trigger with a
one-off routine that runs at once and answers in its chat.

One file per profile, ``<profile home>/.alice/places.json``. iOS watches at most 20
regions per app, so at most 20 triggers.
"""

from __future__ import annotations

import json
import os
import secrets
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

FILE = Path(".alice") / "places.json"
MAX_TRIGGERS = 20
DEFAULT_RADIUS = 150
WHEN = ("arrive", "leave")
# One arrival is one arrival: GPS jitter at the edge must not fire it twice.
REFIRE_AFTER = 30 * 60
_lock = threading.Lock()


class PlaceError(ValueError):
    pass


def _text(value: Any, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def _path(home: Path) -> Path:
    return Path(home) / FILE


def read(home: Path) -> List[Dict[str, Any]]:
    try:
        data = json.loads(_path(home).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    rows = data.get("triggers") if isinstance(data, dict) else None
    return [r for r in rows or [] if isinstance(r, dict) and r.get("id")]


def _write(home: Path, rows: List[Dict[str, Any]]) -> None:
    target = _path(home)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(target.parent), prefix=".places-")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({"triggers": rows}, handle, ensure_ascii=False, indent=1)
    os.replace(tmp, target)


def _coordinate(value: Any, low: float, high: float) -> Optional[float]:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if low <= number <= high else None


def add(home: Path, place: str, when: str, task: str, *, repeat: bool = False,
        lat: Any = None, lon: Any = None, radius: Any = None, now: Optional[float] = None) -> Dict[str, Any]:
    place, task, when = _text(place, 120), _text(task, 600), str(when or "").strip().lower()
    if not place:
        raise PlaceError("Say which place, e.g. 'Mercadona de Súria' or 'casa'.")
    if not task:
        raise PlaceError("Say what to do when it happens.")
    if when not in WHEN:
        raise PlaceError("`when` is 'arrive' or 'leave'.")
    try:
        metres = int(float(radius)) if radius not in (None, "") else DEFAULT_RADIUS
    except (TypeError, ValueError):
        metres = DEFAULT_RADIUS
    trigger = {
        "id": "pl_" + secrets.token_hex(5), "place": place, "when": when, "task": task,
        "repeat": bool(repeat), "radius": max(100, min(metres, 2000)),
        "created_at": now or time.time(),
    }
    la, lo = _coordinate(lat, -90, 90), _coordinate(lon, -180, 180)
    if la is not None and lo is not None:
        trigger.update(lat=la, lon=lo, label=place)
    with _lock:
        rows = read(home)
        if len(rows) >= MAX_TRIGGERS:
            raise PlaceError(f"The iPhone watches at most {MAX_TRIGGERS} places; remove one first.")
        rows.append(trigger)
        _write(home, rows)
    return trigger


def remove(home: Path, trigger_id: str) -> bool:
    with _lock:
        rows = read(home)
        kept = [r for r in rows if r.get("id") != trigger_id]
        if len(kept) == len(rows):
            return False
        _write(home, kept)
    return True


def resolved(home: Path, trigger_id: str, lat: Any, lon: Any, label: str = "") -> Dict[str, Any]:
    """The iPhone found the place on the map: where it is watched from now on."""
    la, lo = _coordinate(lat, -90, 90), _coordinate(lon, -180, 180)
    if la is None or lo is None:
        raise PlaceError("Coordinates are out of range.")
    with _lock:
        rows = read(home)
        for row in rows:
            if row.get("id") == trigger_id:
                row.update(lat=la, lon=lo, label=_text(label, 160) or row.get("place"))
                _write(home, rows)
                return row
    raise PlaceError("That place trigger no longer exists.")


def fired(home: Path, trigger_id: str, event: str, now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """Record an arrival or departure. Returns the trigger to act on, or None when it does not
    apply (other direction, already fired, fired moments ago). A one-time trigger is removed."""
    now = now or time.time()
    with _lock:
        rows = read(home)
        for row in rows:
            if row.get("id") != trigger_id:
                continue
            if row.get("when") != event:
                return None
            if row.get("fired_at") and now - float(row["fired_at"]) < REFIRE_AFTER:
                return None
            row["fired_at"] = now
            if row.get("repeat"):
                _write(home, rows)
            else:
                _write(home, [r for r in rows if r.get("id") != trigger_id])
            return dict(row)
    return None


def prompt_for(trigger: Dict[str, Any]) -> str:
    """What the woken agent reads."""
    moved = "acaba de llegar a" if trigger.get("when") == "arrive" else "acaba de salir de"
    where = trigger.get("label") or trigger.get("place")
    return (
        f"[Aviso por ubicación] La persona {moved} {where}. Esto es lo que te pidió para este momento: "
        f"«{trigger.get('task')}». Hazlo ahora. Si es un recordatorio, escríbele un mensaje breve y útil "
        "para este momento; si es algo que hacer (avisar a alguien, preparar algo), hazlo como en cualquier "
        "tarea y cuéntale en una línea lo que hiciste."
    )


def wake(trigger: Dict[str, Any], now: Optional[datetime] = None) -> Dict[str, Any]:
    """A one-off routine that runs at once in this profile and answers in its chat."""
    from cron.jobs import create_job

    at = (now or datetime.now(timezone.utc)) + timedelta(seconds=5)
    return create_job(prompt_for(trigger), at.isoformat(timespec="seconds"),
                      name=f"Al {'llegar a' if trigger.get('when') == 'arrive' else 'salir de'} {trigger.get('place')}",
                      repeat=1, deliver="bot-chat")


# --- The agent's tool -------------------------------------------------------------------

SCHEMA: Dict[str, Any] = {
    "name": "place_trigger",
    "description": (
        "Do something when the person arrives at or leaves a place, detected by their iPhone "
        "(e.g. 'when I get to the supermarket, remind me of the oil'; 'when I leave work, tell my "
        "partner'). action=add with place (in words, as specific as you know: 'Mercadona, Súria' or "
        "'casa'), when ('arrive' or 'leave'), task (what to do then, in the person's words) and "
        "repeat (true for every time, false for once); lat/lon only if you know them. The iPhone "
        "finds the place on the map near the person. action=list shows them; action=remove takes id. "
        "Use it instead of a timed reminder whenever the request is about a place."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["add", "list", "remove"]},
            "place": {"type": "string"},
            "when": {"type": "string", "enum": list(WHEN)},
            "task": {"type": "string"},
            "repeat": {"type": "boolean"},
            "lat": {"type": "number"},
            "lon": {"type": "number"},
            "radius": {"type": "number", "description": "Metres, 100–2000 (default 150)."},
            "id": {"type": "string"},
        },
        "required": ["action"],
    },
}


def run_tool(home: Path, args: Dict[str, Any]) -> Dict[str, Any]:
    action = str(args.get("action") or "").lower()
    try:
        if action == "add":
            trigger = add(home, args.get("place"), args.get("when"), args.get("task"),
                          repeat=bool(args.get("repeat")), lat=args.get("lat"), lon=args.get("lon"),
                          radius=args.get("radius"))
            return {"ok": True, "trigger": trigger,
                    "next": "Tell the person in one line; their iPhone will start watching the place "
                            "(it may ask them once to allow location 'Always')."}
        if action == "list":
            return {"ok": True, "triggers": read(home)}
        if action == "remove":
            return {"ok": remove(home, str(args.get("id") or ""))}
    except PlaceError as exc:
        return {"ok": False, "error": str(exc)}
    return {"ok": False, "error": "action is add, list or remove."}
