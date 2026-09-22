"""Alice for Hermes.

Most of this plugin lives in the dashboard: ``dashboard/plugin_api.py`` serves pairing,
memory, notes and the shared agent-create/rename engine under ``/api/plugins/alice/``,
and ``dashboard/dist/index.js`` is the Alice tab.

The agent gains one rule: the Business team talks only among itself. A
``pre_tool_call`` hook enforces it, and a system prompt section tells each agent whom
it may message, so it does not try the others. A profile filed in the Business channel (``ui_meta['alice']``, written by
``hermes-agents/business-team/instalar.py``) can message only teammates in that channel,
and nobody outside it can message them. Internal profiles (Evals' sandbox) neither send
nor receive messages.

A note-taking profile also gains a ``notes`` toolset for the store it keeps in
``workspace/inbox-store``, so capturing a note is a tool call instead of a shell command.
No changes to Hermes' own code.
"""
from pathlib import Path

BUSINESS_CHANNEL = "Business (Beta)"
MESSAGE_TOOLS = frozenset({"message_agent"})


def _read_yaml(path: Path) -> dict:
    try:
        import yaml

        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def _placements(root: Path) -> dict:
    """``ui_meta['alice']`` of every named profile."""
    found = {}
    profiles = root / "profiles"
    if not profiles.is_dir():
        return found
    for child in profiles.iterdir():
        meta = _read_yaml(child / "profile.yaml").get("ui_meta")
        placement = meta.get("alice") if isinstance(meta, dict) else None
        if isinstance(placement, dict):
            found[child.name] = placement
    return found


def business_members(root: Path) -> set:
    """The profiles filed in the Business channel."""
    return {name for name, placement in _placements(root).items()
            if isinstance(placement.get("channel"), str)
            and placement["channel"].strip().casefold() == BUSINESS_CHANNEL.casefold()}


def internal_profiles(root: Path) -> set:
    """Technical profiles agents run on, such as Evals' sandbox: not anyone's teammate."""
    return {name for name, placement in _placements(root).items() if placement.get("internal") is True}


def _root_and_sender(home: Path) -> tuple:
    if home.parent.name == "profiles":
        return home.parent.parent, home.name
    return home, "default"


def _local_name(target: str) -> str:
    name = str(target or "").strip().lstrip("@").lower()
    # The mention middleware aliases the default profile as @hermes.
    return "default" if name == "hermes" else name


def _handles(names) -> str:
    return ", ".join(f"@{'hermes' if n == 'default' else n}" for n in sorted(names)) or "nadie"


def business_verdict(root: Path, sender: str, target: str):
    """None when the message may go; otherwise why it may not. A target that is not a
    local teammate (another machine, a peer) counts as outside the team."""
    receiver = _local_name(target)
    internal = internal_profiles(root)
    if receiver in internal:
        return f"No enviado: @{receiver} es un perfil técnico interno y no recibe mensajes. No lo reintentes."
    if sender in internal:
        return "No enviado: este perfil técnico interno no envía mensajes a otros agentes."
    members = business_members(root)
    if not members:
        return None
    sender_inside, receiver_inside = sender in members, receiver in members
    if sender_inside and not receiver_inside:
        return (f"No enviado: eres del equipo de Business y solo puedes escribir a tu equipo "
                f"({_handles(members - {sender})}); «{target}» está fuera. Resuélvelo con tu equipo "
                "o, si hace falta alguien de fuera, díselo al CEO en tu respuesta. No lo reintentes.")
    if receiver_inside and not sender_inside:
        return (f"No enviado: @{receiver} es del equipo de Business y solo recibe mensajes de su equipo. "
                "Si hace falta, díselo al CEO en tu respuesta. No lo reintentes.")
    return None


def team_prompt_for(root: Path, me: str) -> str:
    """What an agent is told about whom it may message, so it does not even try
    the ones Hermes will refuse. Empty when there is nothing to say."""
    heading = "## Con quién puedes hablar\n"
    if me in internal_profiles(root):
        return heading + "Eres un perfil técnico interno: no escribas a ningún agente."
    members = business_members(root)
    if not members:
        return ""
    if me in members:
        return heading + (
            f"Eres del equipo de Business. Con `message_agent` solo puedes escribir a: {_handles(members - {me})}. "
            "El resto de agentes de tu lista de compañeros **no existen para ti**: no les escribas, no los menciones "
            "y no expliques que no puedes escribirles. Si te piden consultar a uno de ellos, consulta a los tuyos y "
            "responde a lo que se pedía, sin una línea sobre el que falta.")
    return heading + (
        f"Los agentes del equipo de Business ({_handles(members)}) no están disponibles para ti: no les escribas "
        "ni lo intentes, aunque te lo pidan, porque Hermes bloquea esos mensajes.")


def team_prompt(_session_info=None) -> str:
    try:
        from hermes_constants import get_hermes_home

        root, me = _root_and_sender(Path(get_hermes_home()))
        return team_prompt_for(root, me)
    except Exception:
        return ""


def _pre_tool_call(tool_name=None, args=None, **_):
    if tool_name not in MESSAGE_TOOLS:
        return None
    try:
        from hermes_constants import get_hermes_home

        # Context-local: under a multiplexed gateway this is the home of the profile whose
        # turn is running, so the sender is the agent making the call.
        root, sender = _root_and_sender(Path(get_hermes_home()))
        reason = business_verdict(root, sender, (args or {}).get("target") or "")
    except Exception:
        # The team's boundary is a rule, not a preference: when it cannot be checked, the
        # message does not go.
        reason = "No enviado: no se pudo comprobar si el mensaje respeta el equipo de Business."
    return {"action": "block", "message": reason} if reason else None

# ── Notes tools ──────────────────────────────────────────────────────────────
# A note-taking profile keeps its notes in its own ``workspace/inbox-store``, driven by
# ``inbox.py``. Reaching it through the terminal tool is what made Hermes ask permission
# before every capture: the note's text arrives as a heredoc piped into an interpreter,
# which is exactly what the security scanner is there to stop. The commands are the same
# here, as tools: no shell to scan, no quoting to get wrong, no approval to wait for, and
# no interpreter to start. A profile without that store sees none of these tools.

NOTES_STORE = Path("workspace") / "inbox-store"
NOTES_TOOLSET = "notes"


def _notes_root() -> Path:
    from hermes_constants import get_hermes_home

    return Path(get_hermes_home()) / NOTES_STORE


def _store_module():
    """The store's own ``inbox.py``, imported from the running profile's workspace."""
    import importlib.util

    root = _notes_root()
    script = root / "inbox.py"
    if not script.is_file():
        return None, None
    spec = importlib.util.spec_from_file_location("alice_inbox_store", script)
    if spec is None or spec.loader is None:
        return None, None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, root


def _store_call(work) -> str:
    """Runs ``work(module, root)`` and returns what the store printed, as its commands do."""
    import io
    import json
    from contextlib import redirect_stdout

    module, root = _store_module()
    if module is None:
        return json.dumps({"ok": False, "error": "este perfil no tiene un almacén de notas"},
                          ensure_ascii=False)
    printed = io.StringIO()
    try:
        with redirect_stdout(printed):
            work(module, root)
    except SystemExit:
        pass  # `inbox.py` reports a refusal by printing it and exiting; the text is the answer.
    except Exception as exc:
        return json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False)
    return printed.getvalue().strip() or json.dumps({"ok": True}, ensure_ascii=False)


def _has_notes_store(**_) -> bool:
    try:
        return (_notes_root() / "inbox.py").is_file()
    except Exception:
        return False


_TEXT = {"type": "string"}
_IDS = {"type": "array", "items": {"type": "string"}}
_TAGS = {"type": "string", "description": "De 1 a 3 etiquetas separadas por comas."}
_FOLDER = {"type": "string", "description": "Nombre o id de una carpeta que ya exista."}
_LIMIT = {"type": "integer", "description": "Cuántas notas devolver como máximo."}


def _ids(args) -> list:
    return [str(i) for i in (args.get("ids") or []) if str(i)]


# name, emoji, description, (properties, required), call
NOTE_TOOLS = (
    ("note_add", "📥",
     "Guarda una nota en el almacén, tal cual, y la archiva en una carpeta que ya exista. "
     "Devuelve su id, su carpeta y sus etiquetas.",
     ({"text": dict(_TEXT, description="El texto exacto de la nota, sin reescribir."),
       "folder": dict(_FOLDER, description="Carpeta existente; omítela para dejarla en Quick Notes."),
       "tags": _TAGS}, ["text"]),
     lambda a, m, root: m.cmd_add(root, str(a.get("text") or ""), a.get("folder"), a.get("tags"))),

    ("note_file", "🗂",
     "Archiva notas ya guardadas en una carpeta, y opcionalmente cambia sus etiquetas.",
     ({"ids": dict(_IDS, description="Ids de las notas a archivar."),
       "folder": dict(_FOLDER, description="Carpeta existente; «none» las devuelve a Quick Notes."),
       "tags": dict(_TAGS, description="De 1 a 3 etiquetas; omítelas para conservar las suyas.")},
      ["ids"]),
     lambda a, m, root: m.cmd_file(root, _ids(a), a.get("folder") or "none", a.get("tags"))),

    ("note_folders", "📁",
     "Las carpetas del almacén con cuántas notas tiene cada una, las etiquetas en uso y "
     "cuántas notas siguen sin archivar.",
     ({}, []),
     lambda a, m, root: m.cmd_folders(root)),

    ("note_folder_create", "➕",
     "Crea una carpeta. Solo después de que la persona haya aprobado esa carpeta concreta.",
     ({"name": dict(_TEXT, description="Nombre de la carpeta, como lo aprobó la persona.")},
      ["name"]),
     lambda a, m, root: m.cmd_folder_create(root, str(a.get("name") or ""))),

    ("note_folder_rename", "✏️",
     "Cambia el nombre de una carpeta. Sus notas se quedan dentro.",
     ({"folder": _FOLDER, "name": dict(_TEXT, description="El nombre nuevo.")}, ["folder", "name"]),
     lambda a, m, root: m.cmd_folder_rename(root, str(a.get("folder") or ""),
                                            str(a.get("name") or ""))),

    ("note_folder_delete", "🗑",
     "Borra una carpeta. Sus notas vuelven a Quick Notes; ninguna nota se pierde.",
     ({"folder": _FOLDER}, ["folder"]),
     lambda a, m, root: m.cmd_folder_delete(root, str(a.get("folder") or ""))),

    ("note_get", "🔎",
     "Una nota entera por su id, con su enriquecimiento.",
     ({"id": _TEXT}, ["id"]),
     lambda a, m, root: m.cmd_get(root, str(a.get("id") or ""))),

    ("note_search", "🔍",
     "Busca notas por texto, con filtros opcionales de fecha y de tipo.",
     ({"query": dict(_TEXT, description="Qué buscar."),
       "start": dict(_TEXT, description="Fecha ISO desde la que buscar (AAAA-MM-DD)."),
       "end": dict(_TEXT, description="Fecha ISO hasta la que buscar (AAAA-MM-DD)."),
       "type": dict(_TEXT, description="Solo notas de este tipo."),
       "limit": _LIMIT}, ["query"]),
     lambda a, m, root: m.cmd_search(root, str(a.get("query") or ""), a.get("start"), a.get("end"),
                                     a.get("type"), int(a.get("limit") or 20))),

    ("note_recent", "🕒",
     "Las notas de los últimos días, de la más nueva a la más vieja.",
     ({"days": {"type": "integer", "description": "Cuántos días atrás mirar."}, "limit": _LIMIT}, []),
     lambda a, m, root: m.cmd_recent(root, int(a.get("days") or 7), int(a.get("limit") or 50))),

    ("note_similar", "🪞",
     "Notas parecidas a un texto. Para no duplicar lo que ya está guardado.",
     ({"text": _TEXT, "limit": _LIMIT}, ["text"]),
     lambda a, m, root: m.cmd_similar(root, str(a.get("text") or ""), int(a.get("limit") or 5))),

    ("note_unprocessed", "📌",
     "Las notas que aún no se han enriquecido.",
     ({"limit": _LIMIT}, []),
     lambda a, m, root: m.cmd_unprocessed(root, int(a.get("limit") or 50))),

    ("note_enrich", "✨",
     "Guarda el enriquecimiento de una nota (types, topics, entities, actions, "
     "open_questions, implicit_important, summary). Conserva su carpeta y sus etiquetas.",
     ({"id": _TEXT,
       "payload": {"type": "object", "description": "Los campos del enriquecimiento."}},
      ["id", "payload"]),
     lambda a, m, root: m.cmd_enrich(root, str(a.get("id") or ""), a.get("payload") or {})),

    ("note_mark_processed", "✅",
     "Marca notas como ya procesadas, para que la rutina no las vuelva a mirar.",
     ({"ids": _IDS}, ["ids"]),
     lambda a, m, root: m.cmd_mark_processed(root, _ids(a))),

    ("note_digest_week", "📰",
     "Los datos de los últimos días agrupados para el resumen semanal.",
     ({"days": {"type": "integer", "description": "Cuántos días cubre el resumen."}}, []),
     lambda a, m, root: m.cmd_digest_week(root, int(a.get("days") or 7))),

    ("note_relate", "🔗",
     "Relaciona dos notas, solo cuando la relación es clara.",
     ({"a": dict(_TEXT, description="Id de la primera nota."),
       "b": dict(_TEXT, description="Id de la segunda nota."),
       "kind": dict(_TEXT, description="Qué tipo de relación es (duplica, continúa, contradice…)."),
       "note": dict(_TEXT, description="Una línea explicando la relación.")},
      ["a", "b", "kind"]),
     lambda a, m, root: m.cmd_relate(root, str(a.get("a") or ""), str(a.get("b") or ""),
                                     str(a.get("kind") or ""), str(a.get("note") or ""))),
)


def _register_notes_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in NOTE_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset=NOTES_TOOLSET, schema=schema,
            handler=lambda args, _call=call, **_: _store_call(
                lambda m, root, _a=args or {}: _call(_a, m, root)),
            check_fn=_has_notes_store, description=description, emoji=emoji,
        )


def _agent_engine():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "agent_engine.py"
    name = "alice_agent_engine"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _free_web():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "free_web.py"
    name = "alice_free_web"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _is_agent_maker(**_) -> bool:
    """Agent Maker's tools follow the stamped role, including after a rename."""
    try:
        from hermes_constants import get_hermes_home

        root, me = _root_and_sender(Path(get_hermes_home()))
        return _agent_engine().is_agent_maker(root, me)
    except Exception:
        return False


def _agent_json(payload: dict) -> str:
    import json

    return json.dumps(payload, ensure_ascii=False)


AGENT_TOOLS = (
    ("agent_create", "🛠️",
     "Crea o configura un agente de Hermes a partir de una especificación validada. "
     "No inventes otros comandos. Si Alice ya creó el perfil para ESTE encargo, "
     "pasa reuse_profile y el mismo job_id. Un perfil de otro trabajo no se reutiliza.",
     ({"spec": {"type": "object", "description":
                "title o name, description, soul con ## Ejemplos, tools, routines, "
                "model y provider. reuse_profile solo con el job_id que creó ese perfil."},
       "job_id": dict(_TEXT, description="El mismo trabajo reanuda y no duplica.")},
      ["spec"]),
     lambda a: _agent_engine().create_from_tool(a or {})),
    ("agent_rename", "✏️",
     "Renombra un agente y su perfil Hermes, conservando conversaciones, instrucciones, "
     "rutinas y credenciales. No elige otro identificador si el nombre está ocupado.",
     ({"from": dict(_TEXT, description="Identificador actual del perfil."),
       "to": dict(_TEXT, description="Nombre visible nuevo (Agent Maker → agent-maker)."),
       "job_id": dict(_TEXT, description="El mismo trabajo reanuda y no duplica.")},
      ["from", "to"]),
     lambda a: _agent_engine().rename_from_tool(a or {})),
)


def _register_agent_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in AGENT_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset="alice_agents", schema=schema,
            handler=lambda args, _call=call, **_: _agent_json(_call(args or {})),
            check_fn=_is_agent_maker, description=description, emoji=emoji,
        )


_ERROR_MARKS = ("fail", "error", "timeout", "losttouch", "reconnecting", "endedunseen")


def _always(**_) -> bool:
    return True


def _diagnostics_reports(root: Path) -> list:
    import json

    folder = root / ".alice" / "diagnostics"
    if not folder.is_dir():
        return []
    found = []
    for path in folder.glob("*.json"):
        if path.name.startswith("."):
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(data, dict):
            data["_mtime"] = path.stat().st_mtime
            found.append(data)
    found.sort(key=lambda row: row.get("_mtime") or 0, reverse=True)
    return found


def alice_app_status(_args=None) -> str:
    try:
        from hermes_constants import get_hermes_home

        root, _ = _root_and_sender(Path(get_hermes_home()))
        reports = _diagnostics_reports(root)
    except Exception as exc:
        return _agent_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    if not reports:
        return _agent_json({"ok": True, "reports": 0, "note": "no dump from the phone yet"})
    latest = reports[0]
    return _agent_json({
        "ok": True,
        "reports": len(reports),
        "device_id": latest.get("device_id"),
        "captured_at": latest.get("captured_at"),
        "version": latest.get("version"),
        "build": latest.get("build"),
        "revision": latest.get("revision"),
        "wellbeing": latest.get("wellbeing"),
        "connected": latest.get("connected"),
        "dashboard_ready": latest.get("dashboard_ready"),
        "gateway_configured": latest.get("gateway_configured"),
        "unknown_events": latest.get("unknown_events") or [],
        "line_count": len(latest.get("lines") or []),
    })


def alice_recent_errors(_args=None) -> str:
    try:
        from hermes_constants import get_hermes_home

        root, _ = _root_and_sender(Path(get_hermes_home()))
        reports = _diagnostics_reports(root)
    except Exception as exc:
        return _agent_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
    if not reports:
        return _agent_json({"ok": True, "errors": [], "note": "no dump from the phone yet"})
    lines = reports[0].get("lines") or []
    errors = [
        line for line in lines
        if any(mark in str(line).lower() for mark in _ERROR_MARKS)
    ]
    return _agent_json({"ok": True, "errors": errors[-40:], "scanned": len(lines)})


def debug_prompt(_session_info=None) -> str:
    return (
        "## Alice app diagnostics\n"
        "When the person asks what is wrong with Alice or the iPhone app, "
        "call `alice_app_status` and `alice_recent_errors` before guessing. "
        "Do not invent connection state. Typical causes: notConfigured means they "
        "have not paired; unreachable means local network, Tailscale or Hermes is "
        "down; reconnecting or lostTouch means the gateway dropped mid-turn and "
        "Alice does not retry mutations; turn.failed is the last send; unknown "
        "event kinds are stream events Alice has not learnt, and the reply should "
        "still have been kept.\n"
    )


DEBUG_TOOLS = (
    ("alice_app_status", "📱",
     "Connection, build and unknown events from the last dump the iPhone uploaded. "
     "Call this before guessing why Alice is failing.",
     ({}, []),
     lambda _a: alice_app_status()),
    ("alice_recent_errors", "⚠️",
     "Recent failure, timeout and reconnect lines from the last dump the iPhone uploaded.",
     ({}, []),
     lambda _a: alice_recent_errors()),
)


def _register_debug_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in DEBUG_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset="alice_debug", schema=schema,
            handler=lambda args, _call=call, **_: _call(args or {}),
            check_fn=_always, description=description, emoji=emoji,
        )


def _calendar():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "calendar_snapshot.py"
    name = "alice_calendar_snapshot"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def calendar_events_tool(args=None) -> str:
    """The person's calendar, read on demand so a long chat never works from a stale copy."""
    try:
        from hermes_constants import get_hermes_home

        root, _ = _root_and_sender(Path(get_hermes_home()))
        a = args or {}
        return _agent_json(_calendar().events(
            root, days_ahead=float(a.get("days_ahead", 7) or 7),
            days_back=float(a.get("days_back", 0) or 0),
        ))
    except Exception as exc:
        return _agent_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


CALENDAR_TOOLS = (
    ("calendar_events", "📅",
     "Marc's calendar, as his iPhone last sent it (read-only). Always returns `status`: "
     "`connected` with the events in the window asked for; `not_connected` when he has not "
     "connected it; `declined` when he said not now. Call it before answering anything about "
     "his schedule, plans, free time, meetings or trips.",
     ({"days_ahead": {"type": "number", "description": "How many days ahead to include (default 7, at most 60)."},
       "days_back": {"type": "number", "description": "How many days back to include (default 0)."}}, []),
     calendar_events_tool),
)


def _register_calendar_tools(ctx) -> None:
    for name, emoji, description, (properties, required), call in CALENDAR_TOOLS:
        schema = {"name": name, "description": description,
                  "parameters": {"type": "object", "properties": properties, "required": required}}
        ctx.register_tool(
            name=name, toolset="alice_calendar", schema=schema,
            handler=lambda args, _call=call, **_: _call(args or {}),
            check_fn=_always, description=description, emoji=emoji,
        )


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", _pre_tool_call)
    # Frozen into each new session prompt; a SOUL change refreshes Bot Chats.
    ctx.register_system_prompt_section("alice.equipos", team_prompt)
    ctx.register_system_prompt_section("alice.debug", debug_prompt)
    _register_notes_tools(ctx)
    # Search and page reading free first (Exa, Jina); Firecrawl only as fallback.
    _free_web().register(ctx)
    _register_agent_tools(ctx)
    _register_debug_tools(ctx)
    _register_calendar_tools(ctx)
