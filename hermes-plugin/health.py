"""The person's health, as their iPhone's Health app keeps it, read so Alice can say what matters.

The iPhone sends one row per day (``POST /api/plugins/alice/health``): sleep hours, steps, active
energy, workout minutes, resting heart rate and heart-rate variability. A WHOOP, Apple Watch or any
wearable that writes to Health arrives the same way. Kept per installation in
``<root>/.alice/health.json`` (at most ``MAX_DAYS``), never logged.

What is read from it is careful on purpose, so Alice does not invent patterns:

- **Notable today** compares last night and yesterday with the person's own last 28 days and says
  nothing unless something is clearly off (thresholds below): quiet days produce nothing.
- **Patterns** need ``MIN_DAYS`` days where both values exist and a correlation of at least
  ``MIN_R``; they look at the same day and the next day ("late workouts → shorter sleep that night").
- **Before / after** compares the averages either side of a date the person names.
- **Week** compares this week with the previous one and names the best and the hardest day.

All of it is plain statistics in the standard library; no model decides what is significant.
"""

from __future__ import annotations

import json
import math
import os
import statistics
import tempfile
import threading
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

FILE = Path(".alice") / "health.json"
MAX_DAYS = 400
BASELINE_DAYS = 28
MIN_BASELINE = 7
MIN_DAYS = 14
MIN_R = 0.4

# What each metric is called, how it is written and which way is good.
METRICS: Dict[str, Dict[str, Any]] = {
    "sleep_h": {"name": "sueño", "unit": "h", "digits": 1, "better": "up"},
    "hrv": {"name": "variabilidad del pulso (HRV)", "unit": "ms", "digits": 0, "better": "up"},
    "rhr": {"name": "pulso en reposo", "unit": "lpm", "digits": 0, "better": "down"},
    "steps": {"name": "pasos", "unit": "", "digits": 0, "better": "up"},
    "active_kcal": {"name": "energía activa", "unit": "kcal", "digits": 0, "better": "up"},
    "workout_min": {"name": "ejercicio", "unit": "min", "digits": 0, "better": "up"},
}
_lock = threading.Lock()


class HealthError(ValueError):
    pass


# --- Storage -------------------------------------------------------------------------------

def _path(root: Path) -> Path:
    return Path(root) / FILE


def read(root: Path) -> Dict[str, Any]:
    try:
        data = json.loads(_path(root).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"connected": False, "days": {}}
    if not isinstance(data, dict):
        return {"connected": False, "days": {}}
    data.setdefault("days", {})
    return data


def _clean_day(row: Dict[str, Any]) -> Optional[Tuple[str, Dict[str, float]]]:
    day = str(row.get("date") or "")
    try:
        date.fromisoformat(day)
    except ValueError:
        return None
    values = {}
    for key in METRICS:
        value = row.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
            values[key] = round(float(value), 2)
    return (day, values) if values else None


def save(root: Path, rows: List[Dict[str, Any]], now: Optional[datetime] = None) -> Dict[str, Any]:
    """Merge the phone's days into what is kept (a later send of a day replaces it)."""
    with _lock:
        data = read(root)
        days = dict(data.get("days") or {})
        for row in rows[: MAX_DAYS]:
            cleaned = _clean_day(row) if isinstance(row, dict) else None
            if cleaned:
                days[cleaned[0]] = cleaned[1]
        kept = dict(sorted(days.items())[-MAX_DAYS:])
        data = {"connected": True, "updated_at": (now or datetime.now()).isoformat(timespec="seconds"), "days": kept}
        target = _path(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(target.parent), prefix=".health-")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        os.chmod(tmp, 0o600)
        os.replace(tmp, target)
    return {"ok": True, "days": len(kept)}


def disconnect(root: Path) -> Dict[str, Any]:
    with _lock:
        target = _path(root)
        if target.exists():
            target.unlink()
    return {"ok": True}


# --- Reading ---------------------------------------------------------------------------------

def _series(days: Dict[str, Dict[str, float]], metric: str) -> Dict[str, float]:
    return {d: v[metric] for d, v in days.items() if metric in v}


def fmt(metric: str, value: float) -> str:
    meta = METRICS[metric]
    if metric == "sleep_h":
        hours = int(value)
        return f"{hours} h {round((value - hours) * 60):02d} min"
    number = f"{value:,.{meta['digits']}f}".replace(",", ".")
    return f"{number} {meta['unit']}".strip()


def baseline(days: Dict[str, Dict[str, float]], metric: str, before: str) -> Optional[Tuple[float, float, int]]:
    """Mean, standard deviation and count of the ``BASELINE_DAYS`` before ``before``."""
    start = (date.fromisoformat(before) - timedelta(days=BASELINE_DAYS)).isoformat()
    values = [v for d, v in _series(days, metric).items() if start <= d < before]
    if len(values) < MIN_BASELINE:
        return None
    return statistics.fmean(values), (statistics.pstdev(values) or 0.0), len(values)


def notable(root: Path, today: Optional[date] = None) -> List[str]:
    """What is clearly off last night or yesterday against the person's own normal. Often empty."""
    days = read(root).get("days") or {}
    today = today or date.today()
    lines = []
    checks = [("sleep_h", today), ("hrv", today), ("rhr", today),
              ("steps", today - timedelta(days=1)), ("workout_min", today - timedelta(days=1))]
    for metric, day in checks:
        key = day.isoformat()
        value = (days.get(key) or {}).get(metric)
        base = baseline(days, metric, key)
        if value is None or base is None:
            continue
        mean, sd, _ = base
        change = (value - mean) / mean if mean else 0.0
        z = (value - mean) / sd if sd else 0.0
        worse = (value < mean) if METRICS[metric]["better"] == "up" else (value > mean)
        # Clearly off: far from the usual spread AND a change a person would feel.
        big = abs(z) >= 1.5 and (abs(change) >= 0.15 or (metric == "rhr" and abs(value - mean) >= 4)
                                 or (metric == "sleep_h" and abs(value - mean) >= 0.75))
        if metric == "sleep_h" and value < 6 and value < mean:
            big = True
        # Only what is worse than usual needs attention; a good night is not news.
        if not big or not worse:
            continue
        when = "anoche" if day == today else "ayer"
        direction = "por debajo" if value < mean else "por encima"
        lines.append(f"- {METRICS[metric]['name']} {when}: {fmt(metric, value)}, "
                     f"{abs(change) * 100:.0f} % {direction} de tu media de 4 semanas ({fmt(metric, mean)})")
    return lines


def _pearson(xs: List[float], ys: List[float]) -> Optional[float]:
    if len(xs) < 2 or statistics.pstdev(xs) == 0 or statistics.pstdev(ys) == 0:
        return None
    return statistics.correlation(xs, ys)


PAIRS = [  # (cause, effect, lag in days): the effect is read on the same day or the next one.
    ("workout_min", "sleep_h", 1), ("steps", "sleep_h", 1), ("sleep_h", "hrv", 0),
    ("sleep_h", "rhr", 0), ("workout_min", "hrv", 1), ("active_kcal", "sleep_h", 1),
]


def patterns(root: Path, window_days: int = 90, today: Optional[date] = None) -> List[Dict[str, Any]]:
    """Relations that hold in the person's own data, strongest first; nothing without enough days."""
    days = read(root).get("days") or {}
    today = today or date.today()
    start = (today - timedelta(days=window_days)).isoformat()
    found = []
    for cause, effect, lag in PAIRS:
        causes, effects = _series(days, cause), _series(days, effect)
        xs, ys = [], []
        for day, x in causes.items():
            if day < start:
                continue
            later = (date.fromisoformat(day) + timedelta(days=lag)).isoformat()
            if later in effects:
                xs.append(x)
                ys.append(effects[later])
        if len(xs) < MIN_DAYS:
            continue
        r = _pearson(xs, ys)
        if r is None or abs(r) < MIN_R:
            continue
        found.append({"cause": cause, "effect": effect, "lag": lag, "r": round(r, 2), "days": len(xs),
                      "text": _pattern_text(cause, effect, lag, r, xs, ys)})
    return sorted(found, key=lambda p: -abs(p["r"]))


def _pattern_text(cause: str, effect: str, lag: int, r: float, xs: List[float], ys: List[float]) -> str:
    median = statistics.median(xs)
    high = [y for x, y in zip(xs, ys) if x > median]
    low = [y for x, y in zip(xs, ys) if x <= median]
    when = "esa noche" if (lag == 1 and effect == "sleep_h") else ("al día siguiente" if lag else "ese día")
    if high and low:
        diff = statistics.fmean(high) - statistics.fmean(low)
        return (f"Los días con más {METRICS[cause]['name']}, tu {METRICS[effect]['name']} {when} "
                f"es {fmt(effect, abs(diff))} {'mayor' if diff > 0 else 'menor'} (en {len(xs)} días)")
    return f"{METRICS[cause]['name']} y {METRICS[effect]['name']} van {'juntos' if r > 0 else 'al revés'} ({len(xs)} días)"


def before_after(root: Path, metric: str, since: str, window_days: int = 30) -> Dict[str, Any]:
    """Averages before and after a date the person names ('since I started walking…')."""
    if metric not in METRICS:
        raise HealthError(f"metric is one of {', '.join(METRICS)}")
    try:
        pivot = date.fromisoformat(since)
    except ValueError:
        raise HealthError("since is a date, YYYY-MM-DD") from None
    series = _series(read(root).get("days") or {}, metric)
    lo, hi = (pivot - timedelta(days=window_days)).isoformat(), (pivot + timedelta(days=window_days)).isoformat()
    before = [v for d, v in series.items() if lo <= d < since]
    after = [v for d, v in series.items() if since <= d < hi]
    if len(before) < MIN_BASELINE or len(after) < MIN_BASELINE:
        return {"enough_data": False, "before_days": len(before), "after_days": len(after)}
    b, a = statistics.fmean(before), statistics.fmean(after)
    return {"enough_data": True, "metric": metric, "before": fmt(metric, b), "after": fmt(metric, a),
            "change_pct": round((a - b) / b * 100, 1) if b else None,
            "before_days": len(before), "after_days": len(after)}


def week(root: Path, today: Optional[date] = None) -> List[str]:
    """Last 7 days against the 7 before, with the best and the hardest day (by sleep and HRV)."""
    days = read(root).get("days") or {}
    today = today or date.today()
    this = [(today - timedelta(days=i)).isoformat() for i in range(1, 8)]
    prev = [(today - timedelta(days=i)).isoformat() for i in range(8, 15)]
    lines = []
    for metric in ("sleep_h", "hrv", "rhr", "steps", "workout_min"):
        now_vals = [days[d][metric] for d in this if metric in days.get(d, {})]
        old_vals = [days[d][metric] for d in prev if metric in days.get(d, {})]
        if len(now_vals) < 4 or len(old_vals) < 4:
            continue
        a, b = statistics.fmean(now_vals), statistics.fmean(old_vals)
        change = (a - b) / b * 100 if b else 0
        arrow = "igual" if abs(change) < 5 else ("↑" if change > 0 else "↓")
        lines.append(f"- {METRICS[metric]['name']}: {fmt(metric, a)} de media ({arrow} {abs(change):.0f} % vs semana anterior)")
    scored = []
    for d in this:
        row = days.get(d, {})
        parts = []
        for metric in ("sleep_h", "hrv"):
            base = baseline(days, metric, d)
            if metric in row and base and base[1]:
                parts.append((row[metric] - base[0]) / base[1])
        if parts:
            scored.append((statistics.fmean(parts), d))
    if len(scored) >= 4:
        scored.sort()
        names = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
        best, worst = date.fromisoformat(scored[-1][1]), date.fromisoformat(scored[0][1])
        lines.append(f"- Mejor día: {names[best.weekday()]}; el más flojo: {names[worst.weekday()]} (por sueño y HRV)")
    return lines


def goal_progress(root: Path, metric: str, target: float, direction: str = "at_least",
                  window_days: int = 7, today: Optional[date] = None) -> Optional[Dict[str, Any]]:
    """A metric goal's progress from real data: the recent average against the target."""
    if metric not in METRICS:
        return None
    days = read(root).get("days") or {}
    today = today or date.today()
    recent = [days[d][metric] for d in ((today - timedelta(days=i)).isoformat() for i in range(0, window_days + 1))
              if metric in days.get(d, {})]
    if len(recent) < max(3, window_days // 2):
        return None
    average = statistics.fmean(recent)
    if direction == "at_most":
        ratio = 1.0 if average <= target else max(0.0, 1 - (average - target) / target)
    else:
        ratio = min(1.0, average / target) if target else 0.0
    return {"average": fmt(metric, average), "percent": round(ratio * 100), "met": ratio >= 1.0}


def summary(root: Path, days: int = 7, today: Optional[date] = None) -> Dict[str, Any]:
    data = read(root)
    if not data.get("connected"):
        return {"status": "not_connected"}
    today = today or date.today()
    rows = data.get("days") or {}
    recent = {d: rows[d] for d in sorted(rows) if d >= (today - timedelta(days=days)).isoformat()}
    return {"status": "connected", "updated_at": data.get("updated_at"), "days": recent,
            "notable": notable(root, today), "patterns": [p["text"] for p in patterns(root, today=today)[:3]]}


# --- The agent's tool ----------------------------------------------------------------------

SCHEMA: Dict[str, Any] = {
    "name": "health",
    "description": (
        "The person's health from their iPhone's Health app (and any wearable that writes to it, such "
        "as WHOOP or Apple Watch): daily sleep, steps, active energy, workout minutes, resting heart "
        "rate and HRV. action=summary (recent days, what is notable against their own normal, and "
        "patterns that hold in their data); action=before_after with metric and since (YYYY-MM-DD) to "
        "answer 'has X helped since I started…'; action=week for this week against the last. Informational, "
        "never a diagnosis; only mention patterns this tool reports. status not_connected: offer "
        "[Conectar Salud](alice://connect/health)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["summary", "before_after", "week"]},
            "days": {"type": "integer"},
            "metric": {"type": "string", "enum": list(METRICS)},
            "since": {"type": "string"},
        },
        "required": ["action"],
    },
}


def run_tool(root: Path, args: Dict[str, Any]) -> Dict[str, Any]:
    action = str(args.get("action") or "summary")
    if not read(root).get("connected"):
        return {"status": "not_connected"}
    try:
        if action == "before_after":
            return before_after(root, str(args.get("metric") or ""), str(args.get("since") or ""))
        if action == "week":
            return {"week": week(root)}
        return summary(root, int(args.get("days") or 7))
    except HealthError as exc:
        return {"ok": False, "error": str(exc)}
