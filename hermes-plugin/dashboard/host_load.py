"""Live CPU and memory of this Mac, and the processes using them.

A single ``ps`` percent is a decaying average of a process's whole life, so a
quiet app that worked hard yesterday still looks busy. The number here is the
change in cumulative CPU time between two readings, divided by the wall time
between them. The first reading only starts the clock. Process names come
from the executable path, never from the argument list, which can carry
secrets.
"""
from __future__ import annotations

import os
import re
import signal
import socket
import subprocess
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

# pid, cumulative CPU time, resident KB, command name (not arguments).
_ROW = re.compile(r"^\s*(\d+)\s+(\S+)\s+(\d+)\s+(.+?)\s*$")
_PAGE = re.compile(r"page size of (\d+) bytes")
_MIN_WINDOW = 0.4
_TOP = 20
# Ending these takes the screen, the login, or Alice's own connection with them.
_PROTECTED = frozenset({"kernel_task", "launchd", "WindowServer", "loginwindow"})
# A macOS service name and the part of the Mac it is doing.
_SERVICE_EFFECT = {
    "mds": "Spotlight search",
    "mdworker": "Spotlight search",
    "mds_stores": "Spotlight search",
    "backupd": "Time Machine",
    "coreaudiod": "sound",
    "bluetoothd": "Bluetooth",
    "sharingd": "AirDrop and sharing",
    "cloudd": "iCloud",
    "trustd": "signing in and passwords",
    "securityd": "signing in and passwords",
    "airportd": "Wi-Fi",
    "nsurlsessiond": "downloads",
    "runningboardd": "which apps are allowed to run",
    "distnoted": "notifications between apps",
}
# Open apps whose closing does more than drop unsaved work in a window.
_APP_EFFECT = {
    "Finder": "Stopping it closes Finder. Open folders disappear until it starts again.",
    "Docker": "Stopping it closes Docker and the containers it is running.",
    "Docker Desktop": "Stopping it closes Docker and the containers it is running.",
}

# pid -> (cpu_seconds, rss_bytes, comm)
ProcessRow = Tuple[float, int, str]

_lock = threading.Lock()
_previous: Optional[Dict[str, Any]] = None
_names: Dict[int, str] = {}
# A one-second sample is mostly noise. Most of the last reading is kept, so a
# process has to stay busy for a few seconds before the number walks over.
_SMOOTH_KEEP = 0.75
_cpu_smooth: Dict[int, float] = {}
_machine_smooth: Optional[float] = None


def reset_for_tests() -> None:
    global _previous, _machine_smooth
    with _lock:
        _previous = None
        _machine_smooth = None
        _names.clear()
        _cpu_smooth.clear()


def smooth(previous: Optional[float], instant: float) -> float:
    if previous is None:
        return instant
    return previous * _SMOOTH_KEEP + instant * (1.0 - _SMOOTH_KEEP)


def settle(
    report: Dict[str, Any],
    cpu_state: Dict[int, float],
    machine_state: Optional[float],
) -> Tuple[Dict[str, Any], Dict[int, float], Optional[float]]:
    """Damp a fresh reading so idle jitter does not redraw the screen."""
    if report.get("warming"):
        return report, cpu_state, machine_state
    machine = smooth(machine_state, float(report["cpu"]["percent"]))
    report["cpu"]["percent"] = float(round(machine))
    kept: Dict[int, float] = {}
    rows: List[Dict[str, Any]] = []
    for row in report["processes"]:
        cpu = row["cpu"]
        if cpu is None:
            rows.append(row)
            continue
        value = smooth(cpu_state.get(row["pid"]), float(cpu))
        kept[row["pid"]] = value
        rows.append({**row, "cpu": float(round(value))})
    total = int(report["memory"].get("total") or 0)
    if total > 0:
        step = max(total // 100, 1)
        used = int(report["memory"]["used"])
        report["memory"]["used"] = int(round(used / step) * step)
    report["processes"] = _select(rows)
    return report, kept, machine


def parse_cputime(text: str) -> float:
    """``ps`` cumulative time: ``[[dd-]hh:]mm:ss[.fraction]``."""
    days = 0.0
    if "-" in text:
        day, text = text.split("-", 1)
        days = float(day)
    parts = text.split(":")
    if len(parts) == 3:
        hours, minutes, seconds = parts
    elif len(parts) == 2:
        hours, minutes, seconds = "0", parts[0], parts[1]
    else:
        return 0.0
    return days * 86400 + float(hours) * 3600 + float(minutes) * 60 + float(seconds)


def parse_ps(text: str) -> Dict[int, ProcessRow]:
    found: Dict[int, ProcessRow] = {}
    for line in text.splitlines():
        match = _ROW.match(line)
        if not match:
            continue
        pid = int(match.group(1))
        if pid <= 0:
            continue
        ticks = parse_cputime(match.group(2))
        rss = int(match.group(3)) * 1024
        comm = match.group(4).strip() or str(pid)
        found[pid] = (ticks, rss, comm)
    return found


def parse_vm_stat(text: str, total: int) -> Dict[str, int]:
    page = 4096
    match = _PAGE.search(text)
    if match:
        page = int(match.group(1))
    pages: Dict[str, int] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        number = value.strip().rstrip(".")
        if number.isdigit():
            pages[key.strip()] = int(number)
    free = pages.get("Pages free", 0) * page
    speculative = pages.get("Pages speculative", 0) * page
    wired = pages.get("Pages wired down", 0) * page
    compressor = pages.get("Pages occupied by compressor", 0) * page
    used = max(0, total - free - speculative)
    return {"used": used, "total": total, "wired": wired, "compressor": compressor}


def pressure(memory: Dict[str, int]) -> str:
    """How tight memory is, from the kernel's own free percentage when we have it.

    Counting every inactive page as used makes a Mac that is merely caching
    files look full. ``kern.memorystatus_level`` is the percentage the system
    itself still calls free.
    """
    free = memory.get("free_percent")
    if isinstance(free, int):
        if free <= 10:
            return "critical"
        if free <= 20:
            return "tight"
        return "ok"
    total = memory.get("total") or 0
    if total <= 0:
        return "ok"
    used = memory.get("used", 0) / total
    if used >= 0.92:
        return "critical"
    if used >= 0.80:
        return "tight"
    return "ok"


def build_report(
    previous: Optional[Dict[int, ProcessRow]],
    current: Dict[int, ProcessRow],
    elapsed: float,
    memory: Dict[str, int],
    cores: int,
    load: Tuple[float, float, float],
    host: str,
    sampled_at: float,
    name_of: Callable[[int, str], str],
) -> Dict[str, Any]:
    """One reading. ``previous`` absent means the clock just started."""
    warming = previous is None or elapsed < _MIN_WINDOW
    rows: List[Dict[str, Any]] = []
    busy = 0.0
    for pid, (ticks, rss, comm) in current.items():
        cpu: Optional[float] = None
        if previous is not None and not warming:
            prior = previous.get(pid)
            if prior is not None:
                cpu = max(0.0, (ticks - prior[0]) / elapsed * 100.0)
                busy += cpu
        rows.append({
            "pid": pid,
            "name": name_of(pid, comm),
            "cpu": None if cpu is None else round(cpu, 1),
            "memory": rss,
        })
    cores = max(1, cores)
    machine = 0.0 if warming else min(100.0, busy / cores)
    return {
        "host": host,
        "warming": warming,
        "sampledAt": sampled_at,
        "cpu": {
            "percent": round(machine, 1),
            "cores": cores,
            "load": [round(load[0], 2), round(load[1], 2), round(load[2], 2)],
        },
        "memory": {
            "used": memory["used"],
            "total": memory["total"],
            "compressor": memory.get("compressor", 0),
            "pressure": pressure(memory),
        },
        "processes": _select(rows),
    }


def _select(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """The processes worth a glance: busy ones, large ones, then the rest."""
    notable = [
        row for row in rows
        if (row["cpu"] or 0) >= 3 or row["memory"] >= 150 * 1024 * 1024
    ]
    if len(notable) < 8:
        seen = {row["pid"] for row in notable}
        for row in sorted(rows, key=lambda item: item["memory"], reverse=True):
            if row["pid"] in seen:
                continue
            notable.append(row)
            seen.add(row["pid"])
            if len(notable) >= 8:
                break
    notable.sort(key=lambda item: ((item["cpu"] or 0), item["memory"]), reverse=True)
    return notable[:_TOP]


def current() -> Dict[str, Any]:
    """The latest picture. Serialised so two polls share one clock."""
    with _lock:
        return _current_locked()


def _current_locked() -> Dict[str, Any]:
    global _previous, _cpu_smooth, _machine_smooth
    ps = _run(["/bin/ps", "-axo", "pid=,cputime=,rss=,comm="])
    processes = parse_ps(ps)
    memsize = int(_run(["/usr/sbin/sysctl", "-n", "hw.memsize"]).strip() or "0")
    memory = parse_vm_stat(_run(["/usr/bin/vm_stat"]), memsize)
    free_percent = _free_percent()
    if free_percent is not None and memsize > 0:
        memory["free_percent"] = free_percent
        memory["used"] = memsize * (100 - free_percent) // 100
    cores = os.cpu_count() or 1
    load = os.getloadavg()
    now = time.time()
    previous = _previous
    elapsed = 0.0 if previous is None else now - float(previous["at"])
    report = build_report(
        None if previous is None else previous["processes"],
        processes,
        elapsed,
        memory,
        cores,
        (float(load[0]), float(load[1]), float(load[2])),
        _hostname(),
        now,
        _name_of,
    )
    _previous = {"at": now, "processes": processes}
    report, _cpu_smooth, _machine_smooth = settle(report, _cpu_smooth, _machine_smooth)
    own = {os.getpid(), os.getppid()}
    for row in report["processes"]:
        path = _executable_path(row["pid"]) or ""
        row.update(consequence(row["name"], path, row["pid"] in own))
    return report


def _name_of(pid: int, comm: str) -> str:
    cached = _names.get(pid)
    if cached:
        return cached
    name = _executable(pid) or comm.rsplit("/", 1)[-1] or comm
    _names[pid] = name
    if len(_names) > 4000:
        _names.clear()
        _names[pid] = name
    return name


def _executable(pid: int) -> Optional[str]:
    path = _executable_path(pid)
    if not path:
        return None
    base = os.path.basename(path)
    return base or None


def _executable_path(pid: int) -> Optional[str]:
    try:
        import ctypes
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(1024)
        count = library.proc_pidpath(pid, buffer, 1024)
        if count <= 0:
            return None
        path = buffer.value.decode("utf-8", "replace")
        return path or None
    except Exception:
        return None


def consequence(name: str, path: str, own: bool) -> Dict[str, str]:
    """What stopping this process would disturb.

    ``session`` keeps the Mac usable. ``connection`` is Alice's link to it.
    ``service`` is a system piece. ``app`` and ``helper`` touch something that
    is open. ``task`` ends only itself.
    """
    if own:
        return {
            "effect": "connection",
            "effectTitle": "Disconnects Alice",
            "effectDetail": "This is Alice’s connection to the Mac. Stopping it disconnects this phone.",
            "affects": "Alice",
        }
    if name in _PROTECTED:
        return {
            "effect": "session",
            "effectTitle": "Keeps the Mac running",
            "effectDetail": f"{name} keeps the screen and your session running. Alice will not stop it.",
            "affects": "this Mac",
        }
    app = _app_name(path, name)
    if _is_helper(name, path):
        return {
            "effect": "helper",
            "effectTitle": f"Part of {app}",
            "effectDetail": (
                f"This is part of {app}, which is open. Stopping it can make {app} "
                "glitch or quit. Other apps keep running."
            ),
            "affects": app,
        }
    if ".app/" in path:
        extra = _APP_EFFECT.get(app)
        detail = extra or (
            f"{app} is open. Stopping it closes {app}. Unsaved work in {app} can be lost."
        )
        return {
            "effect": "app",
            "effectTitle": f"Open app · closes {app}",
            "effectDetail": detail,
            "affects": app,
        }
    if _is_system(path) or name in _SERVICE_EFFECT:
        what = _SERVICE_EFFECT.get(name)
        if what:
            title = f"System service · {what}"
            detail = (
                f"{name} is how this Mac does {what}. "
                "Stopping it can interrupt that until it starts again."
            )
        else:
            title = "System service"
            detail = (
                f"{name} is part of macOS. "
                "Stopping it can interrupt that part of the Mac until it starts again."
            )
        return {"effect": "service", "effectTitle": title, "effectDetail": detail, "affects": "this Mac"}
    return {
        "effect": "task",
        "effectTitle": "Only this process",
        "effectDetail": f"Stopping {name} ends that process. Other apps keep running.",
        "affects": name,
    }


def _app_name(path: str, fallback: str) -> str:
    if ".app/" in path:
        leaf = path.split(".app/")[0].rsplit("/", 1)[-1]
        if leaf:
            return leaf
    for token in (" Helper", " Renderer"):
        if token in fallback:
            return fallback.split(token)[0]
    return fallback


def _is_helper(name: str, path: str) -> bool:
    lowered = name.lower()
    return (
        "helper" in lowered
        or "renderer" in lowered
        or "/xpcservices/" in path.lower()
    )


def _is_system(path: str) -> bool:
    return path.startswith((
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/lib/", "/sbin/", "/Library/Apple/",
    ))


def _free_percent() -> Optional[int]:
    try:
        raw = _run(["/usr/sbin/sysctl", "-n", "kern.memorystatus_level"]).strip()
        percent = int(raw)
    except Exception:
        return None
    return max(0, min(100, percent))


def refusal(pid: int, name: str, actual: Optional[str], own: set) -> Optional[str]:
    """Why this stop must not happen, or None when it is the process we were shown."""
    if pid <= 1 or pid in own or name in _PROTECTED:
        return f"{name} keeps this Mac running."
    if not actual or actual != name:
        return "That process already ended."
    return None


def stop_process(pid: int, name: str) -> Dict[str, Any]:
    """End one process the phone named. The name has to still belong to that pid."""
    name = name.strip()
    reason = refusal(pid, name, _executable(pid), {os.getpid(), os.getppid()})
    if reason:
        return {"ok": False, "error": reason}
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return {"ok": True, "pid": pid}
    except PermissionError:
        return {"ok": False, "error": "macOS will not let Alice stop that process."}
    deadline = time.monotonic() + 0.8
    while time.monotonic() < deadline:
        if not _alive(pid):
            return {"ok": True, "pid": pid}
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return {"ok": True, "pid": pid}
    except PermissionError:
        return {"ok": False, "error": "macOS will not let Alice stop that process."}
    time.sleep(0.05)
    if _alive(pid):
        return {"ok": False, "error": f"{name} is still running."}
    return {"ok": True, "pid": pid}


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _hostname() -> str:
    name = socket.gethostname().split(".")[0].strip()
    return name or "Mac"


def _run(argv: List[str]) -> str:
    completed = subprocess.run(
        argv,
        check=True,
        capture_output=True,
        text=True,
        timeout=2,
    )
    return completed.stdout
