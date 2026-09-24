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
import contextvars
import threading
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


def _action_log():
    import importlib.util
    import sys

    path = Path(__file__).resolve().parent / "action_log.py"
    name = "alice_action_log"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _post_tool_call(tool_name=None, args=None, result=None, session_id="", status=None, **_):
    """Keeps what an agent did that changed something — sent, scheduled, signed in, deleted —
    for Alice's Activity. An observer: it never changes the call, and a failure here is
    swallowed so it can never break a turn."""
    try:
        from hermes_constants import get_hermes_home

        root, profile = _root_and_sender(Path(get_hermes_home()))
        _action_log().observe(root, profile, tool_name=tool_name or "", args=args, result=result,
                              session_id=session_id or "", status=status)
    except Exception:
        pass
    if tool_name == "skill_manage" and status != "error":
        # A skill written now is kept now, unless it reads like an injection (skill_keeper.py).
        _keep_skills(delay=1.0)
    if tool_name == "memory" and status != "error":
        _keep_memory(args, session_id or "")
    return None


def _memory_keeper():
    return _module("memory_keeper.py", "alice_memory_keeper")


def _keep_memory(args, session_id: str) -> None:
    """An agent just wrote to memory: note where the entry came from, then tidy (or only
    propose, by default). Never raises into the turn."""
    try:
        from hermes_constants import get_hermes_home

        home = Path(get_hermes_home())
        _, profile = _root_and_sender(home)
        a = args if isinstance(args, dict) else {}
        target = str(a.get("target") or "memory")
        keeper_module = _memory_keeper()
        keeper = keeper_module.Keeper(home, keeper_module.HermesFiles())
        # Recorded before anything looks: an entry nobody recorded reads as hand-written.
        operations = a.get("operations") if isinstance(a.get("operations"), list) else [a]
        targets = set()
        for op in operations:
            if not isinstance(op, dict):
                continue
            op_target = str(op.get("target") or target)
            targets.add(op_target)
            text = op.get("content") or op.get("new_text") or op.get("new_content")
            if op.get("action") in ("add", "replace") and text:
                keeper.record(op_target, str(text), "agent", session=session_id, profile=profile)
        keeper.run(targets=tuple(t for t in sorted(targets) if t in keeper_module.TARGETS))
    except Exception:
        pass


# A conversation counts as paused after this long without a new turn; then what the person
# said in it is read once for facts about them that were not kept (memory_review.py).
_REVIEW_AFTER_S = 90
_review_timers: dict = {}
_review_lock = threading.Lock()


def _skill_keeper():
    return _module("skill_keeper.py", "alice_skill_keeper")


def _keep_skills(delay: float = 0.0) -> None:
    try:
        from hermes_constants import get_hermes_home

        _skill_keeper().run_soon(Path(get_hermes_home()), delay=delay)
    except Exception:
        pass


def _keep_reviewed_skills(**_) -> None:
    """Hermes reviews a finished conversation in the background and may stage skills from it."""
    _keep_skills(delay=120.0)


def _schedule_memory_review(session_id="", platform="", **_) -> None:
    """Each finished turn restarts its conversation's wait; the look happens once it is quiet."""
    try:
        if not session_id or str(platform or "") == "cron":
            return
        from hermes_constants import get_hermes_home

        home = Path(get_hermes_home())
        root, profile = _root_and_sender(home)
        if profile in internal_profiles(root):
            return
        key = f"{home}|{session_id}"
        # The profile the turn ran under travels with the look, on another thread.
        context = contextvars.copy_context()
        timer = threading.Timer(_REVIEW_AFTER_S, lambda: context.run(_review_memory, home, profile, session_id))
        timer.daemon = True
        with _review_lock:
            previous = _review_timers.pop(key, None)
            if previous:
                previous.cancel()
            _review_timers[key] = timer
        timer.start()
    except Exception:
        pass


def _review_ask(messages):
    """The profile's own model, so the person's words go nowhere their conversation did not
    already go — unless ``auxiliary.alice_memory_review`` chooses another on purpose."""
    from agent.auxiliary_client import call_llm, extract_content_or_reasoning
    from hermes_cli.config import load_config

    config = load_config() or {}
    chosen = ((config.get("auxiliary") or {}).get("alice_memory_review") or {})
    model = config.get("model") or {}
    route = {} if chosen.get("provider") or not isinstance(model, dict) else {
        "provider": model.get("provider") or None, "model": model.get("default") or None,
        "base_url": model.get("base_url") or None}
    response = call_llm(task="alice_memory_review", messages=messages, max_tokens=900, timeout=90, **route)
    return extract_content_or_reasoning(response) or ""


def _review_memory(home: Path, profile: str, session_id: str) -> None:
    key = f"{home}|{session_id}"
    with _review_lock:
        _review_timers.pop(key, None)
    try:
        from hermes_state import SessionDB

        keeper_module = _module("memory_keeper.py", "alice_memory_keeper")
        review = _module("memory_review.py", "alice_memory_review")
        keeper = keeper_module.Keeper(home, keeper_module.HermesFiles())
        if not keeper.settings()["learn"] or not keeper.files.store.target_enabled("user"):
            return
        seen = keeper._read("reviewed.json", {})
        seen = seen if isinstance(seen, dict) else {}
        db = SessionDB(read_only=True)
        try:
            session = db.get_session(session_id) or {}
            if str(session.get("source") or "") == "cron":
                return
            after = seen.get(session_id)
            messages = db.get_messages(session_id, after_id=int(after) if after else None)
        finally:
            db.close()
        if not messages:
            return
        turns = review.person_turns(messages)
        if turns:
            review.review(turns, keeper, _review_ask, session=session_id, profile=profile)
        # Read once: the same words are never looked at again, whatever the model said.
        seen[session_id] = max(int(m.get("id") or 0) for m in messages) or after
        keeper._write("reviewed.json", dict(list(seen.items())[-500:]))
    except Exception:
        pass


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


def secret_prompt(_session_info=None) -> str:
    """How an agent gets a key it needs, without the key ever entering the chat."""
    return (
        "## Claves y tokens\n"
        "Si para un comando o una herramienta necesitas una clave, token o contraseña de la persona, "
        "**nunca se la pidas en el chat** ni le pidas que la pegue en un mensaje o en la terminal. "
        "Di en una frase para qué la necesitas y dónde conseguirla, y termina con esta línea sola: "
        "`[Dar clave](alice://connect/secret/NOMBRE)`, con NOMBRE en mayúsculas como variable de entorno "
        "(por ejemplo `EXA_API_KEY`). Alice la pide en un campo seguro y la guarda como `NOMBRE=…` en "
        "`~/.hermes/.env` y en el `.env` de cada perfil. Cuando diga que está, úsala desde ahí sin mostrarla: "
        "`NOMBRE=\"$(sed -n 's/^NOMBRE=//p' ~/.hermes/.env | tr -d '\\\"')\" comando`. "
        "Nunca imprimas, repitas ni resumas su valor, ni lo escribas en notas, memoria o archivos. "
        "No uses nombres de la configuración de Hermes (`HERMES_*`, `API_SERVER_*`)."
    )


def resolve_prompt(_session_info=None) -> str:
    """Finish what was asked: obstacles are part of the task, not a reason to stop."""
    return (
        "## Terminar lo que te piden\n"
        "Cuando te piden hacer algo (comprar, reservar, rellenar, buscar, gestionar), tu trabajo es "
        "**dejarlo hecho**, no informar de por qué no se pudo. Los imprevistos son parte del trabajo: "
        "una cesta con cosas de antes, un aviso de cookies, un pop-up, una sesión caducada, un error "
        "de la página, un botón que no responde, un campo que falta, un paso que no esperabas.\n"
        "Ante cada obstáculo, antes de responder:\n"
        "1. **Entiende qué pasa**: mira la página (captura o texto) en vez de suponer.\n"
        "2. **Resuélvelo tú si es reversible y encaja con lo pedido**: corrige cantidades, quita lo que "
        "sobra de un intento anterior, rechaza cookies no esenciales, cierra pop-ups, vuelve a iniciar "
        "sesión, recarga, espera, prueba otra ruta (otro botón, la búsqueda, la URL directa), elige la "
        "opción estándar o la más barata cuando no te dijeron otra. No preguntes por nada de esto.\n"
        "3. **Si falla, prueba otra cosa**: al menos dos o tres enfoques distintos antes de rendirte.\n"
        "4. **Comprueba el resultado** después de cada acción importante: que la cesta, el formulario "
        "o la reserva dicen lo que debían.\n"
        "Solo te paras en tres casos: (a) un paso **irreversible** —pagar, enviar, publicar, borrar—, "
        "para el que basta **un sí** por tarea que cubre hasta el final (al pagar con tarjeta, ese sí es "
        "la confirmación de Hermes, sin preguntar también en el chat); (b) algo "
        "que **cambia lo que te pidieron** —otro producto, más precio del visto, un coste extra, una "
        "fecha distinta—; (c) algo que **solo la persona tiene** —una contraseña, una tarjeta, un "
        "código— y que se pide con su tarjeta segura, nunca en el chat.\n"
        "Cuando te pares, deja todo listo y pregunta **una sola cosa, con una propuesta concreta** "
        "(«Hay otro producto en la cesta; lo quito y sigo, ¿vale?»), para que baste un «sí». "
        "Nunca termines con «no he avanzado» o «no he podido» sin haber intentado arreglarlo, y si de "
        "verdad no se puede, di qué probaste y qué propones ahora.\n"
        "**Tareas que piden pensar** (planificar, comparar opciones, decidir, investigar, algo con "
        "dinero, fechas o salud): antes de empezar, fíjate en silencio en tres cosas — qué tiene que "
        "ser verdad para que la respuesta sirva (precio, fecha, disponibilidad, requisito), qué dato te "
        "falta y dónde lo compruebas, y qué error sería caro. Compruébalo con las herramientas en vez "
        "de suponer. Al terminar, da la respuesta y, solo si algo quedó sin comprobar o dependía de "
        "una suposición, añade una línea «Sin comprobar: …». No lo hagas en preguntas sencillas ni "
        "enseñes este proceso: la persona ve el resultado, no el andamiaje.\n"
        + _task_finish().prompt()
    )


# Channels that show text as it comes: markdown would show as ** and [text](url).
_PLAIN_TEXT_PLATFORMS = {"photon", "sms", "imessage", "bluebubbles"}


def _text_channel():
    return _module("text_channel.py", "alice_text_channel")


def _plain_text_reply(**kwargs):
    return _text_channel().transform(**kwargs)


def channel_prompt(session_info=None) -> str:
    """How to write when the person reads Alice in iMessage or SMS rather than the app."""
    platform = str((session_info or {}).get("platform") or "").lower()
    if platform not in _PLAIN_TEXT_PLATFORMS:
        return ""
    return (
        "## Estás en iMessage\n"
        "La persona te lee en iMessage, que muestra el texto tal cual: **nada de Markdown** — sin "
        "asteriscos, almohadillas, tablas ni enlaces con corchetes. Escribe como un mensaje de texto "
        "entre personas: frases cortas, lo importante primero, y si hay varias cosas, una por línea "
        "empezando con «•». Los enlaces van como la dirección sola en su propia línea "
        "(https://…), nunca como [texto](url). Nunca un párrafo largo: una idea por párrafo, "
        "con una línea en blanco entre ellos. Por ejemplo:\n"
        "Hoy en Chollometro, lo mejor:\n\n"
        "• Sandwichera Create: 21,80 € (antes 54,95 €)\n"
        "• Lidl: 3 € de descuento en compras de 30 €, solo hoy\n\n"
        "Ojo: el de Apple Music es para estudiantes de India.\n\n"
        "https://www.chollometro.com/ofertas"
    )


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
            days_back=float(a.get("days_back", 0) or 0), tz=_calendar().zone(root),
        ))
    except Exception as exc:
        return _agent_json({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


CALENDAR_TOOLS = (
    ("calendar_events", "📅",
     "The person's calendar, as their iPhone last sent it (read-only). Always returns `status`: "
     "`connected` with the events in the window asked for; `not_connected` when they have not "
     "connected it; `declined` when they said not now. Call it before answering anything about "
     "their schedule, plans, free time, meetings or trips.",
     ({"days_ahead": {"type": "number", "description": "How many days ahead to include (default 7, at most 60)."},
       "days_back": {"type": "number", "description": "Whole days before today to include (default 0: from midnight today, so this morning is always in)."}}, []),
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


# ── Page watches, PDF forms, spending, and the shared browser ──────────────────────


def _module(filename: str, name: str):
    import importlib.util
    import sys

    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _watch():
    return _module("page_watch.py", "alice_page_watch")


def _documents():
    return _module("documents.py", "alice_documents")


def _browser():
    return _module("browser_live.py", "alice_browser_live")


def _hermes_root() -> Path:
    from hermes_constants import get_hermes_home

    return _root_and_sender(Path(get_hermes_home()))[0]


def _tool(call):
    """A handler that answers JSON and never raises: failures are the agent's to explain."""
    def handler(args=None, **_):
        try:
            return _agent_json({"ok": True, **call(args or {})})
        except Exception as exc:  # noqa: BLE001
            return _agent_json({"ok": False, "error": str(exc) or type(exc).__name__})
    return handler


def _watch_create(a):
    from hermes_constants import get_hermes_home

    root, profile = _root_and_sender(Path(get_hermes_home()))
    below = a.get("below")
    return {"watch": _watch().create(
        root, url=str(a.get("url") or ""), kind=str(a.get("kind") or "change"), label=str(a.get("label") or ""),
        below=float(below) if below not in (None, "") else None, text=str(a.get("text") or ""),
        every_minutes=int(a.get("every_minutes") or 60), profile=profile)}


WATCH_TOOLS = (
    ("page_watch_create", "👀",
     "Watch a public web page for the person and tell them when something happens, without them asking again. "
     "kind: `price` (tell when the price drops, or with `below` when it is at or under that amount), `stock` "
     "(tell when it is available again), `text` (tell when `text` appears on the page) or `change` (any change). "
     "Checks every `every_minutes` (default 60, minimum 15); news reaches their Alice chat on its own. Use it "
     "whenever they say «avísame si/cuando…» about a page, a product, tickets or availability. If it says the "
     "feature is not active, tell them to turn it on in Alice › Vigilancias.",
     ({"url": {"type": "string", "description": "The page, http(s)."},
       "kind": {"type": "string", "enum": ["price", "stock", "text", "change"]},
       "label": {"type": "string", "description": "A short name for it, in their language."},
       "below": {"type": "number", "description": "For price: tell when the price is at or under this."},
       "text": {"type": "string", "description": "For text: the words to wait for."},
       "every_minutes": {"type": "integer"}}, ["url", "kind"]),
     _watch_create),
    ("page_watch_list", "👀", "The pages being watched for the person, with the current price, stock and status.",
     ({}, []), lambda a: {"watches": _watch().listing(_hermes_root())}),
    ("page_watch_delete", "👀", "Stop watching a page (by the id page_watch_list gives).",
     ({"id": {"type": "string"}}, ["id"]),
     lambda a: (_watch().delete(_hermes_root(), str(a.get("id") or "")), {"deleted": a.get("id")})[1]),
)

DOCUMENT_TOOLS = (
    ("pdf_form_read", "📄",
     "Read a fillable PDF form: its fields (name, kind, current value, choices) and the start of its text. "
     "`path` is the file's absolute path or its alice://file link.",
     ({"path": {"type": "string"}}, ["path"]),
     lambda a: _documents().form_read(str(a.get("path") or ""))),
    ("pdf_form_fill", "📄",
     "Fill a PDF form's fields exactly and save a copy next to it (…-rellenado.pdf). `values` maps field "
     "names from pdf_form_read to values; for checkboxes use one of the field's options. Then show the copy "
     "as ![Título](alice://file?path=…) so the person can review and sign it on their iPhone before it goes "
     "anywhere. Never invent data you do not have: ask for it.",
     ({"path": {"type": "string"}, "values": {"type": "object"}}, ["path", "values"]),
     lambda a: _documents().form_fill(str(a.get("path") or ""), a.get("values") or {})),
    ("spending_summary", "💶",
     "Add up a bank statement CSV exactly: income, spending, categories, top merchants, months and the "
     "largest payments from a bank CSV. Show a `spending` alice-ui component with the returned "
     "`income`, `spent`, `net`, `currency`, `from`, `to` and `categories` fields unchanged, "
     "then 2–4 plain observations. If `uncategorized` has recognisable merchants, call again with `rules` "
     "({\"text in the description\": \"Category\"}) instead of guessing sums yourself.",
     ({"path": {"type": "string"}, "rules": {"type": "object"}}, ["path"]),
     lambda a: _documents().spending(str(a.get("path") or ""), a.get("rules") or None)),
)


def _register_work_tools(ctx) -> None:
    for toolset, tools in (("alice_watch", WATCH_TOOLS), ("alice_documents", DOCUMENT_TOOLS)):
        for name, emoji, description, (properties, required), call in tools:
            schema = {"name": name, "description": description,
                      "parameters": {"type": "object", "properties": properties, "required": required}}
            ctx.register_tool(name=name, toolset=toolset, schema=schema, handler=_tool(call),
                              check_fn=_always, description=description, emoji=emoji)


BROWSER_HELD = (
    "The person has taken over the shared browser (a sign-in, a verification code, a CAPTCHA "
    "or a payment) and is using it now. Do not use the browser until they hand it back. Tell "
    "them in one short sentence what you will do once they do, then stop; do not retry this "
    "call, and do not open another browser to get around it."
)


def _browser_ready(tool_name=None, **_):
    """Before an agent browses: the shared browser Alice keeps is running — unless the
    person has taken it over, and then the agent waits for it to be handed back."""
    name = str(tool_name or "")
    if not (name.startswith("browser_") or name == "browser"):
        return None
    try:
        root = _hermes_root()
        module = _browser()
        if module.managed(root) and module.control(root)["holder"] == "human":
            return {"action": "block", "message": BROWSER_HELD}
        module.ensure(root)
    except Exception:
        pass
    return None


# ── Goals: what the person wants reached, and Alice's plan (goals.py) ───────────────


def _goals_module():
    return _module("goals.py", "alice_goals")


def _goals_store():
    from hermes_constants import get_hermes_home

    return _goals_module().Goals(Path(get_hermes_home()))


def _cards_module():
    return _module("vault_cards.py", "alice_vault_cards")


def cards_prompt(_session_info=None) -> str:
    try:
        from hermes_cli.profiles import get_active_profile_name

        profile = get_active_profile_name()
    except Exception:
        profile = "default"
    return _cards_module().prompt(profile if profile != "custom" else "default")


def _health():
    return _module("health.py", "alice_health")


def _health_root() -> Path:
    from hermes_constants import get_hermes_home

    root, _ = _root_and_sender(Path(get_hermes_home()))
    return root


def _measured(goal):
    """A measured goal's progress from the person's Health data, or None without enough days."""
    measure = goal.get("measure") or {}
    try:
        return _health().goal_progress(_health_root(), measure["metric"], measure["target"],
                                       measure.get("direction", "at_least"), measure.get("window_days", 7))
    except Exception:
        return None


def goals_prompt(_session_info=None) -> str:
    """The open goals, so the agent knows them and keeps them current."""
    try:
        return _goals_module().prompt_section(_goals_store().list(include_done=False), measured=_measured)
    except Exception:
        return ""


def _register_health_tools(ctx) -> None:
    module = _health()
    ctx.register_tool(
        name="health", toolset="alice_health", schema=module.SCHEMA,
        handler=lambda args, **_: _agent_json(module.run_tool(_health_root(), args or {})),
        check_fn=_always, description=module.SCHEMA["description"], emoji="❤️",
    )


def _places():
    return _module("places.py", "alice_places")


def _register_place_tools(ctx) -> None:
    module = _places()

    def handler(args, **_):
        from hermes_constants import get_hermes_home

        return _agent_json(module.run_tool(Path(get_hermes_home()), args or {}))

    ctx.register_tool(
        name="place_trigger", toolset="alice_places", schema=module.SCHEMA, handler=handler,
        check_fn=_always, description=module.SCHEMA["description"], emoji="📍",
    )


def _task_finish():
    return _module("task_finish.py", "alice_task_finish")


def _register_task_tools(ctx) -> None:
    module = _task_finish()
    ctx.register_tool(
        name="finish_task", toolset="alice_tasks", schema=module.SCHEMA,
        handler=lambda args, **_: _agent_json(module.run_tool(args or {})),
        check_fn=_always, description=module.SCHEMA["description"], emoji="🏁",
    )


def _register_goal_tools(ctx) -> None:
    module = _goals_module()
    ctx.register_tool(
        name="goals", toolset="alice_goals", schema=module.SCHEMA,
        handler=lambda args, **_: _agent_json(module.run_tool(_goals_store(), args or {}, measured=_measured)),
        check_fn=_always, description=module.SCHEMA["description"], emoji="🎯",
    )


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", _pre_tool_call)
    # The shared browser the iPhone can watch is started before an agent needs it.
    ctx.register_hook("pre_tool_call", _browser_ready)
    # What each agent did with consequences, for Alice's Activity.
    ctx.register_hook("post_tool_call", _post_tool_call)
    # In iMessage and SMS the reply is made readable as a text message (text_channel.py).
    ctx.register_hook("transform_llm_output", _plain_text_reply)
    # What the person said about themselves and no agent kept, read once a conversation pauses.
    ctx.register_hook("on_session_end", _schedule_memory_review)
    # And what Hermes learned from it is kept, once reviewed (skill_keeper.py).
    ctx.register_hook("on_session_end", _keep_reviewed_skills)
    # Frozen into each new session prompt; a SOUL change refreshes Bot Chats.
    ctx.register_system_prompt_section("alice.equipos", team_prompt)
    ctx.register_system_prompt_section("alice.debug", debug_prompt)
    ctx.register_system_prompt_section("alice.resolver", resolve_prompt)
    ctx.register_system_prompt_section("alice.canal", channel_prompt)
    ctx.register_system_prompt_section("alice.claves", secret_prompt)
    ctx.register_system_prompt_section("alice.tarjetas", cards_prompt)
    ctx.register_system_prompt_section("alice.objetivos", goals_prompt)
    _register_goal_tools(ctx)
    # A task of several steps is kept going by Hermes' goal judge until done or it needs the person.
    _register_task_tools(ctx)
    # When the person arrives at or leaves a place, their iPhone wakes the agent (places.py).
    _register_place_tools(ctx)
    # Sleep, activity, heart rate and HRV from the iPhone's Health app (health.py).
    _register_health_tools(ctx)
    _register_notes_tools(ctx)
    # Search and page reading free first (Exa, Jina); Firecrawl only as fallback.
    _free_web().register(ctx)
    _register_agent_tools(ctx)
    _register_debug_tools(ctx)
    _register_calendar_tools(ctx)
    _register_work_tools(ctx)
