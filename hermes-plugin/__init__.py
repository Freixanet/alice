"""Alice for Hermes.

Most of this plugin lives in the dashboard: ``dashboard/plugin_api.py`` serves pairing,
memory and notes under ``/api/plugins/alice/``, and ``dashboard/dist/index.js`` is the
Alice tab.

The agent gains one rule: the Business team talks only among itself. A
``pre_tool_call`` hook enforces it, and a system prompt section tells each agent whom
it may message, so it does not try the others. A profile filed in the Business channel (``ui_meta['alice']``, written by
``hermes-agents/business-team/instalar.py``) can message only teammates in that channel,
and nobody outside it can message them. Internal profiles (Evals' sandbox) neither send
nor receive messages. No tools, commands or changes to Hermes' own code.
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


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", _pre_tool_call)
    # Frozen into each new session prompt; a SOUL change refreshes Bot Chats.
    ctx.register_system_prompt_section("alice.equipos", team_prompt)
