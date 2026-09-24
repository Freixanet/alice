"""The person's goals, and Alice's plan to reach each one.

A goal is something that takes days or weeks — "prepare the kids for school", "find a
flat in Manresa", "run a half marathon in March" — as opposed to a request done in one
turn. Each has a plan (a few concrete steps, ticked as they are done), a short log of
what happened, and the routines working on it in the background. Alice keeps it current
with the ``goals`` tool as she works; the person sees and changes it in the Goals tab
(``GET/POST/PATCH/DELETE /api/plugins/alice/goals``). One file per profile, in
``<profile home>/.alice/goals.json``, written atomically.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

FILE = Path(".alice") / "goals.json"
STATUSES = ("active", "paused", "done")
STEP_STATUSES = ("todo", "doing", "done")
MAX_GOALS = 60
MAX_STEPS = 20
MAX_LOG = 40
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_lock = threading.Lock()


class GoalError(Exception):
    pass


def _text(value: Any, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def _date(value: Any) -> Optional[str]:
    text = str(value or "").strip()
    return text if DATE.match(text) else None


class Goals:
    """The goals of the profile whose home is ``home``."""

    def __init__(self, home: Path, now: Callable[[], float] = time.time):
        self.path = Path(home) / FILE
        self.now = now

    # storage

    def _load(self) -> List[Dict[str, Any]]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        goals = data.get("goals") if isinstance(data, dict) else None
        return [g for g in goals if isinstance(g, dict)] if isinstance(goals, list) else []

    def _save(self, goals: List[Dict[str, Any]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps({"goals": goals}, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(temp, self.path)

    def _mutate(self, change: Callable[[List[Dict[str, Any]]], Any]) -> Any:
        with _lock:
            goals = self._load()
            result = change(goals)
            self._save(goals)
            return result

    @staticmethod
    def _find(goals: List[Dict[str, Any]], goal_id: str) -> Dict[str, Any]:
        for goal in goals:
            if goal.get("id") == goal_id:
                return goal
        raise GoalError(f"No goal with id {goal_id!r}. Call goals with action 'list' for the ids.")

    # reading

    def list(self, include_done: bool = True) -> List[Dict[str, Any]]:
        goals = self._load()
        if not include_done:
            goals = [g for g in goals if g.get("status") != "done"]
        order = {"active": 0, "paused": 1, "done": 2}
        return sorted(goals, key=lambda g: (order.get(g.get("status"), 3), -(g.get("updated_at") or 0)))

    def get(self, goal_id: str) -> Dict[str, Any]:
        return self._find(self._load(), goal_id)

    @staticmethod
    def progress(goal: Dict[str, Any]) -> Dict[str, int]:
        steps = goal.get("steps") or []
        return {"done": sum(1 for s in steps if s.get("status") == "done"), "total": len(steps)}

    @staticmethod
    def next_step(goal: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        steps = goal.get("steps") or []
        return next((s for s in steps if s.get("status") == "doing"), None) \
            or next((s for s in steps if s.get("status") == "todo"), None)

    # writing

    def create(self, title: str, why: str = "", due: Any = None, steps: Optional[List[Any]] = None,
               by: str = "agent") -> Dict[str, Any]:
        title = _text(title, 120)
        if not title:
            raise GoalError("A goal needs a title.")

        def change(goals):
            if len([g for g in goals if g.get("status") != "done"]) >= MAX_GOALS:
                raise GoalError("Too many open goals; finish or remove some first.")
            now = self.now()
            goal = {"id": secrets.token_hex(4), "title": title, "why": _text(why, 400), "status": "active",
                    "due": _date(due), "created_at": now, "updated_at": now, "steps": [], "log": [],
                    "routines": []}
            for step in (steps or [])[:MAX_STEPS]:
                self._add_step(goal, step)
            goal["log"].append({"at": now, "by": by, "text": "Goal set."})
            goals.append(goal)
            return goal

        return self._mutate(change)

    def _add_step(self, goal: Dict[str, Any], step: Any) -> Dict[str, Any]:
        if len(goal["steps"]) >= MAX_STEPS:
            raise GoalError(f"A plan holds at most {MAX_STEPS} steps.")
        text, due = (step.get("text"), step.get("due")) if isinstance(step, dict) else (step, None)
        text = _text(text, 200)
        if not text:
            raise GoalError("A step needs its text.")
        item = {"id": secrets.token_hex(3), "text": text, "status": "todo", "due": _date(due), "done_at": None}
        goal["steps"].append(item)
        return item

    def update(self, goal_id: str, *, title: Any = None, why: Any = None, status: Any = None, due: Any = "",
               note: Any = None, by: str = "agent") -> Dict[str, Any]:
        def change(goals):
            goal = self._find(goals, goal_id)
            if title is not None and _text(title, 120):
                goal["title"] = _text(title, 120)
            if why is not None:
                goal["why"] = _text(why, 400)
            if status is not None:
                if status not in STATUSES:
                    raise GoalError(f"status must be one of {', '.join(STATUSES)}.")
                if status != goal.get("status"):
                    goal["status"] = status
                    words = {"active": "Resumed.", "paused": "Paused.", "done": "Reached."}[status]
                    self._log(goal, words, by)
            if due != "":
                goal["due"] = _date(due)
            if note:
                self._log(goal, _text(note, 400), by)
            goal["updated_at"] = self.now()
            return goal

        return self._mutate(change)

    def step(self, goal_id: str, *, add: Any = None, step_id: Optional[str] = None, status: Any = None,
             text: Any = None, remove: bool = False, by: str = "agent") -> Dict[str, Any]:
        def change(goals):
            goal = self._find(goals, goal_id)
            if add is not None:
                items = add if isinstance(add, list) else [add]
                for item in items:
                    self._add_step(goal, item)
            elif step_id:
                item = next((s for s in goal["steps"] if s.get("id") == step_id), None)
                if item is None:
                    raise GoalError(f"No step {step_id!r} in this goal.")
                if remove:
                    goal["steps"].remove(item)
                else:
                    if text is not None and _text(text, 200):
                        item["text"] = _text(text, 200)
                    if status is not None:
                        if status not in STEP_STATUSES:
                            raise GoalError(f"step status must be one of {', '.join(STEP_STATUSES)}.")
                        item["status"] = status
                        item["done_at"] = self.now() if status == "done" else None
                        if status == "done":
                            self._log(goal, f"Done: {item['text']}", by)
            else:
                raise GoalError("Give 'add' for new steps, or 'step_id' to change one.")
            goal["updated_at"] = self.now()
            return goal

        return self._mutate(change)

    def link_routine(self, goal_id: str, routine: str) -> Dict[str, Any]:
        def change(goals):
            goal = self._find(goals, goal_id)
            routine_id = _text(routine, 64)
            if routine_id and routine_id not in goal["routines"]:
                goal["routines"].append(routine_id)
            goal["updated_at"] = self.now()
            return goal

        return self._mutate(change)

    def remove(self, goal_id: str) -> None:
        def change(goals):
            goals.remove(self._find(goals, goal_id))

        self._mutate(change)

    def _log(self, goal: Dict[str, Any], text: str, by: str) -> None:
        goal.setdefault("log", []).append({"at": self.now(), "by": by if by in ("agent", "person") else "agent",
                                           "text": text})
        goal["log"] = goal["log"][-MAX_LOG:]


# ── What the agent sees ─────────────────────────────────────────────────────────


def summary(goals: List[Dict[str, Any]], limit: int = 12) -> str:
    """The open goals, one line each, for the agent's prompt."""
    lines = []
    for goal in [g for g in goals if g.get("status") != "done"][:limit]:
        progress = Goals.progress(goal)
        nxt = Goals.next_step(goal)
        bits = [f"[{goal['id']}] {goal['title']}"]
        if goal.get("status") == "paused":
            bits.append("(paused)")
        if progress["total"]:
            bits.append(f"{progress['done']}/{progress['total']} steps")
        if goal.get("due"):
            bits.append(f"by {goal['due']}")
        if nxt:
            bits.append(f"next: {nxt['text']}")
        lines.append(" · ".join(bits))
    return "\n".join(lines)


PROMPT = (
    "## Objetivos\n"
    "Lleva los objetivos de la persona con la herramienta `goals` (se ven en la pestaña Objetivos de Alice). "
    "Cuando diga algo que llevará días o semanas —un objetivo, un proyecto, una lista de cosas que "
    "le pesa— créalo con un título corto y un plan de 3 a 7 pasos concretos, y díselo en una línea. "
    "Si un paso necesita vigilar algo o repetirse, crea la rutina y enlázala (`link_routine`). "
    "Mientras trabajas, marca los pasos que terminas y deja una nota breve de lo importante; "
    "márcalo como logrado solo cuando lo esté. Un recado de un solo turno no es un objetivo. "
    "Si te pregunta cómo va algo, responde desde aquí.\n"
)


def prompt_section(goals: List[Dict[str, Any]]) -> str:
    open_goals = summary(goals)
    if not open_goals:
        return PROMPT
    return PROMPT + "\nObjetivos abiertos ahora:\n" + open_goals + "\n"


# ── The tool ────────────────────────────────────────────────────────────────────

ACTIONS = ("list", "create", "update", "step", "link_routine", "remove")

SCHEMA = {
    "name": "goals",
    "description": (
        "The person's goals and your plan for each (shown in Alice's Goals tab). "
        "list: open goals with ids. create: title, why, due (YYYY-MM-DD), steps (list of short texts). "
        "update: goal_id with title/why/due/status (active, paused, done) and/or note (a short progress note). "
        "step: goal_id plus add (text or list) for new steps, or step_id with status (todo, doing, done), "
        "text, or remove=true. link_routine: goal_id and routine (the cronjob id working on it). "
        "remove: goal_id, only when the person asks."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": list(ACTIONS)},
            "goal_id": {"type": "string"},
            "title": {"type": "string"},
            "why": {"type": "string"},
            "due": {"type": "string", "description": "YYYY-MM-DD"},
            "status": {"type": "string"},
            "note": {"type": "string"},
            "steps": {"type": "array", "items": {"type": "string"}},
            "add": {"description": "A step's text, or a list of them.",
                    "anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}]},
            "step_id": {"type": "string"},
            "text": {"type": "string"},
            "remove": {"type": "boolean"},
            "routine": {"type": "string"},
            "include_done": {"type": "boolean"},
        },
        "required": ["action"],
    },
}


def run_tool(store: Goals, args: Dict[str, Any]) -> Dict[str, Any]:
    action = str(args.get("action") or "").strip()
    try:
        if action == "list":
            goals = store.list(include_done=bool(args.get("include_done")))
            return {"ok": True, "goals": [_brief(g) for g in goals]}
        if action == "create":
            return {"ok": True, "goal": store.create(args.get("title"), args.get("why") or "", args.get("due"),
                                                     args.get("steps") or [])}
        goal_id = str(args.get("goal_id") or "")
        if not goal_id:
            raise GoalError("goal_id is required.")
        if action == "update":
            return {"ok": True, "goal": store.update(goal_id, title=args.get("title"), why=args.get("why"),
                                                     status=args.get("status"), due=args.get("due", ""),
                                                     note=args.get("note"))}
        if action == "step":
            return {"ok": True, "goal": store.step(goal_id, add=args.get("add"), step_id=args.get("step_id"),
                                                   status=args.get("status"), text=args.get("text"),
                                                   remove=bool(args.get("remove")))}
        if action == "link_routine":
            return {"ok": True, "goal": store.link_routine(goal_id, args.get("routine") or "")}
        if action == "remove":
            store.remove(goal_id)
            return {"ok": True, "removed": goal_id}
        raise GoalError(f"action must be one of {', '.join(ACTIONS)}.")
    except GoalError as exc:
        return {"ok": False, "error": str(exc)}


def _brief(goal: Dict[str, Any]) -> Dict[str, Any]:
    nxt = Goals.next_step(goal)
    return {"id": goal["id"], "title": goal["title"], "status": goal["status"], "due": goal.get("due"),
            "progress": Goals.progress(goal), "next": nxt and {"id": nxt["id"], "text": nxt["text"]},
            "steps": [{"id": s["id"], "text": s["text"], "status": s["status"]} for s in goal.get("steps") or []]}
