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
    "description": "Create a sandboxed Python watcher only when the person asks to be notified. For create supply name, source, config, non-empty code and created_by_request. Email MUST set config.query to an explicit Gmail search matching the requested sender/topic (for example from:sender@example.com); never use an empty config or guess a company's sender domain. Discover the sender using the connected Gmail search tool or ask the person. If alert criteria are unclear, ask before creating. Execute the script at top level; defining run() alone does nothing. Never redefine classify, notify, ack or other broker capabilities. Write code using event/config, classify(state, questions), state.get/put, notify(message,dedup_key), ack(event_id), log, source.read and source-only http_get. No imports, filesystem, ambient network or other tools. Filter deterministically first; classify action notify/quiet/defer, include quiet and put thresholds in code. Ack quiet or a successful notify only. Create paused. Activation runs the actual code on a source sample, exercises classify/notify/ack, and requires a successful cheap-route dry run with at least one acked or notified event; empty sources or incomplete code cannot activate. Explain the rejection reason, never bypass it. The first live poll establishes a baseline and does not process historical items. New Gmail items are filtered by server arrival time after that baseline. Never claim success after an error. If cheap model setup is missing, tell the person to configure Settings → Watchers; never use the main model. Built-ins: leave_now (verified travel_minutes), birthday (explicit dates), follow_up (explicit due_at timers). Feedback mutes sender/topic or reduces category. Errors retain events; retry or discard explicitly.",
    "parameters": {"type": "object", "properties": {
        "action": {"type": "string", "enum": ["create", "list", "dry_run", "activate", "pause", "retry", "discard", "feedback"]},
        "id": {"type": "string"}, "name": {"type": "string"},
        "source": {"type": "string", "enum": ["email", "feed", "github", "builtin"]},
        "config": {"type": "object", "description": "Source settings. Email requires query; feed requires url; github requires repo; builtin requires kind and its explicit dates/travel settings.", "properties": {
            "query": {"type": "string", "description": "Explicit Gmail search filter matching the requested sender/topic."},
            "every_minutes": {"type": "integer", "minimum": 1, "maximum": 1440},
            "url": {"type": "string"}, "repo": {"type": "string"},
            "kind": {"type": "string", "enum": ["leave_now", "birthday", "follow_up"]},
            "time_zone": {"type": "string"}, "travel_minutes": {"type": "number"},
            "birthdays": {"type": "array", "items": {"type": "object", "properties": {
                "name": {"type": "string"}, "date": {"type": "string"}}, "required": ["name", "date"]}},
            "follow_ups": {"type": "array", "items": {"type": "object", "properties": {
                "id": {"type": "string"}, "subject": {"type": "string"}, "body": {"type": "string"},
                "due_at": {"type": "string"}, "sender": {"type": "string"}, "resolved": {"type": "boolean"}},
                "required": ["id", "subject", "body", "due_at"]}}}},
        "code": {"type": "string", "description": "Required for non-builtin creation: non-empty sandboxed Python implementing the requested notification rule."}, "created_by_request": {"type": "string"},
        "kind": {"type": "string", "enum": ["muted_senders", "muted_topics", "less_categories"]},
        "value": {"type": "string"}, "remove": {"type": "boolean"}}, "required": ["action"]}}
