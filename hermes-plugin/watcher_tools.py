"""Agent tools for user-requested scripts and dry runs; never configure a model implicitly."""
from pathlib import Path
import importlib.util

_spec = importlib.util.spec_from_file_location("alice_watcher_common", Path(__file__).with_name("watcher_common.py"))
_common = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_common)
sibling = _common.sibling


def run(home, args):
    store = sibling("watchers.py").Store(home)
    try:
        action = args.get("action", "list")
        ident = args.get("id", "")
        if action == "create":
            code = args.get("code")
            if args.get("source") == "builtin" and not code:
                code = sibling("watcher_builtins.py").TRIAGE_CODE
            return {"watcher": store.create("local", args["name"], args["source"], args.get("config", {}), code, args["created_by_request"])}
        if action == "list":
            return {"watchers": store.listing(), "setup_required": not bool(store.settings()["route"])}
        if action == "dry_run":
            return {"results": sibling("watchers.py").Engine(store).dry_run(ident)}
        if action in ("activate", "retry"):
            getattr(store, action)(ident)
            try:
                sibling("watcher_service.py").ensure_schedule(home)
            except Exception:
                store.pause(ident)
                raise ValueError("Hermes cron is unavailable; watcher remains paused.")
            return {"watcher": store.get(ident)}
        if action in ("pause", "discard"):
            getattr(store, action)(ident)
            return {"watcher": store.get(ident)}
        if action == "feedback":
            return {"feedback": store.feedback("local", args["kind"], args["value"], args.get("remove", False))}
        raise ValueError("Unknown watcher action.")
    finally:
        store.close()


SCHEMA = {
    "name": "watchers",
    "description": "Create a sandboxed Python watcher only when the person asks to be notified. Write code using event/config, classify(state, questions), state.get/put, notify(message,dedup_key), ack(event_id), log, source.read and source-only http_get. No imports, filesystem, ambient network or other tools. Filter deterministically first; classify action notify/quiet/defer, include quiet and put thresholds in code. Ack quiet or a successful notify only. Create paused, dry_run the last 20 captured items, then activate. If cheap model setup is missing, tell the person to configure Settings → Watchers; never use the main model. Built-ins: leave_now (verified travel_minutes), birthday (explicit dates), follow_up (explicit due_at timers). Feedback mutes sender/topic or reduces category. Errors retain events; retry or discard explicitly.",
    "parameters": {"type": "object", "properties": {
        "action": {"type": "string", "enum": ["create", "list", "dry_run", "activate", "pause", "retry", "discard", "feedback"]},
        "id": {"type": "string"}, "name": {"type": "string"},
        "source": {"type": "string", "enum": ["email", "feed", "github", "builtin"]},
        "config": {"type": "object"}, "code": {"type": "string"}, "created_by_request": {"type": "string"},
        "kind": {"type": "string", "enum": ["muted_senders", "muted_topics", "less_categories"]},
        "value": {"type": "string"}, "remove": {"type": "boolean"}}, "required": ["action"]}}
