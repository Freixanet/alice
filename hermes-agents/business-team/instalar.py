#!/usr/bin/env python3
"""Instala el equipo de Business en el Hermes de este Mac.

Con el Python de Hermes:

    ~/.hermes/hermes-agent/venv/bin/python instalar.py [--comprobar] [--actualizar]

El equipo lo dirige el Chief of Staff, que ya existe: a sus instrucciones se les
añade (o se les actualiza, entre marcadores) la sección de emprendimientos
digitales y lo que comparte el equipo; nada más de ellas cambia.

Los especialistas se crean con la herramienta de Forja (modelo estándar con
reserva, herramientas con la de preguntas, instrucciones con la guía de estilo y
nombre visible). Un especialista que ya existe se deja como está, salvo con
--actualizar: entonces se reescriben sus instrucciones y su descripción; su
modelo y sus herramientas no se tocan.

A todos se les dice a Alice en qué canal y sección aparecen
(`ui_meta['alice']`), solo si cambia. Nunca borra agentes. Imprime un JSON.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FORJA_SCRIPTS = HERE.parent / "forja" / "skill" / "forja-crear-agentes" / "scripts"
HERMES_ROOT = Path.home() / ".hermes" / "hermes-agent"
sys.path.insert(0, str(HERMES_ROOT))
sys.path.insert(0, str(FORJA_SCRIPTS))

CHANNEL = "Business (Beta)"
# The team's shared folder: project state, competitor profiles, the watchlist and
# research reports, readable by every agent. `{{BUSINESS_DIR}}` in the
# instructions becomes this path.
BUSINESS_DIR = Path.home() / "hermes-workspaces" / "business"
# Evals: its harness lives here, where its routines call it, and every
# evaluation runs in the sandbox profile.
EVALS_DIR = Path.home() / "hermes-workspaces" / "evals"
EVALS_TOOL = EVALS_DIR / "herramienta" / "evals.py"
EVALS_SOURCE = HERE.parent / "evals" / "evals.py"
HERMES_PYTHON = HERMES_ROOT / "venv" / "bin" / "python"
SANDBOX = "evals-sandbox"
SANDBOX_TITLE = "Evals · pruebas"
SANDBOX_DESCRIPTION = "Perfil técnico donde Evals ejecuta sus pruebas. No es un compañero: no le envíes mensajes."
# The channel's departments, in the order a venture moves through them:
# understand, define, build, sell. Alice lays the channel out this way and
# drops empty sections left out of it.
DEPARTMENTS = ["Intelligence Dept.", "Product Dept.", "Engineering Dept.", "Revenue Dept."]
LEAD = "chief-of-staff"
BLOCK_START = "<!-- alice:business inicio -->"
BLOCK_END = "<!-- alice:business fin -->"
STYLE_START = "<!-- alice:estilo inicio -->"

TEAM = [
    {"name": "biz-mercado", "department": "Intelligence Dept.", "title": "Mercado", "tools": ["browser"],
     "description": "Clientes, demanda y competencia con fuentes verificables para validar o descartar ideas rápido."},
    {"name": "biz-producto", "department": "Product Dept.", "title": "Producto", "tools": ["browser"],
     "description": "Propuesta de valor, MVP mínimo y experiencia de usuario que hace volver."},
    {"name": "biz-growth", "department": "Revenue Dept.", "title": "Growth", "tools": ["browser"],
     "description": "Posicionamiento, mensajes, canales y experimentos para conseguir clientes al menor coste."},
    {"name": "biz-ingresos", "department": "Revenue Dept.", "title": "Ingresos", "tools": ["code_execution"],
     "description": "Modelo de negocio, precios, ventas y números: CAC, LTV, márgenes y escenarios."},
    {"name": "biz-tech", "department": "Engineering Dept.", "title": "Arquitecto",
     "tools": ["terminal", "code_execution", "browser", "delegation"],
     # Each temporary builder gets its own git worktree, so parallel builders never
     # share a working copy.
     "config": {"delegation.worktree_isolation": True},
     "description": "Diseña antes de construir, reparte el trabajo entre builders temporales en paralelo e integra: stack, seguridad e instrumentación."},
    {"name": "biz-calidad", "department": "Engineering Dept.", "title": "Calidad",
     "tools": ["terminal", "code_execution", "delegation"],
     # A different model from the one that wrote the code catches different
     # mistakes: Luna first, the team's standard model as its fallback.
     "config": {
         "model.default": "gpt-5.6-luna",
         "model.provider": "openai-codex",
         "model.base_url": "https://chatgpt.com/backend-api/codex",
         "fallback_providers": [{"provider": "opencode-free", "model": "muse-spark-1.3-contributor-free", "base_url": ""}],
     },
     "description": "Control independiente: revisa el código que no escribió (bugs, casos límite, seguridad, regresiones, complejidad) y da el visto bueno antes de producción."},
    {"name": "biz-critico", "department": "Intelligence Dept.", "title": "Abogado del diablo", "tools": ["browser"],
     "description": "Pre-mortem, supuestos, riesgos, legal y verificación antes de apostar tiempo o dinero."},
    {"name": "biz-scout", "department": "Intelligence Dept.", "title": "Scout", "tools": ["browser"],
     "description": "Vigila de forma continua competidores, startups, precios, regulación, Reddit/HN/X y tendencias, y avisa de lo que cambia tus apuestas.",
     "routines": [
         {"name": "Scout — ronda diaria", "schedule": "0 8 * * *",
          "prompt": "Haz la ronda diaria del Scout siguiendo tu SOUL.md: lee la lista de vigilancia y el registro, "
                    "cubre solo lo nuevo desde la última ronda, verifica en fuente primaria, actualiza el registro "
                    "y entrega solo señales Urgentes e Importantes. Si no hay ninguna, responde exactamente [SILENT]."},
         {"name": "Scout — informe semanal", "schedule": "0 9 * * 1",
          "prompt": "Haz el informe semanal del Scout siguiendo tu SOUL.md: tendencias de los últimos 7 días según "
                    "tu registro y una exploración nueva, y hasta 3 oportunidades con el problema, quién paga hoy y "
                    "cuánto, por qué ahora, la evidencia y el siguiente paso para validarla. Actualiza el registro."},
     ]},
    {"name": "biz-investigacion", "department": "Intelligence Dept.", "title": "Investigación",
     "tools": ["browser", "code_execution", "delegation"],
     "description": "Investiga a fondo preguntas abiertas y difíciles, con fuentes contrastadas, cálculos, ranking de opciones y el siguiente experimento."},
]


# Evaluates every agent on this Hermes, not only Business; filed loose at the top
# of the channel, next to the Chief of Staff. Judges with Luna, so the team's
# standard model is never its own judge.
EVALS = {
    "name": "evals", "department": None, "title": "Evals",
    "tools": ["terminal", "code_execution", "session_search"],
    "config": {
        "model.default": "gpt-5.6-luna",
        "model.provider": "openai-codex",
        "model.base_url": "https://chatgpt.com/backend-api/codex",
        "fallback_providers": [{"provider": "opencode-free", "model": "muse-spark-1.3-contributor-free", "base_url": ""}],
    },
    "routines": [
        {"name": "Evals — cambios", "schedule": "0 7 * * *",
         "prompt": "Haz la rutina diaria de Evals siguiendo tu SOUL.md (Rutina diaria · cambios). "
                   "Si no hay nada que contar, responde exactamente [SILENT]."},
        {"name": "Evals — modelos", "schedule": "0 5 * * 0",
         "prompt": "Haz la rutina semanal de Evals siguiendo tu SOUL.md (Rutina semanal · modelos)."},
    ],
    "description": "Mide si cada agente hace bien su trabajo: benchmarks propios, regresiones tras cada cambio y torneo de modelos con propuesta de cambio.",
}


def read(path: Path) -> str:
    return (path.read_text(encoding="utf-8").strip()
            .replace("{{BUSINESS_DIR}}", str(BUSINESS_DIR))
            .replace("{{EVALS_DIR}}", str(EVALS_DIR))
            .replace("{{EVALS_CMD}}", f"{HERMES_PYTHON} {EVALS_TOOL}"))


# Templates the installer owns in the shared folder, from compartido/.
TEMPLATES = {
    "competidores/_plantilla.md": "plantilla-competidor.md",
    "proyectos/_plantilla-cliente.md": "plantilla-cliente.md",
    "proyectos/_plantilla-oportunidades.md": "plantilla-oportunidades.md",
    "proyectos/_plantilla-medicion.md": "plantilla-medicion.md",
    "proyectos/_plantilla-diseno.md": "plantilla-diseno.md",
    "proyectos/_plantilla-release.md": "plantilla-release.md",
}
FOLDERS = ("proyectos", "competidores", "investigaciones")


def prepare_shared_folder(check: bool) -> dict:
    """The shared folder and its templates. Never touches what the agents wrote;
    the templates are the installer's own and kept current."""
    changes = [d for d in FOLDERS if not (BUSINESS_DIR / d).is_dir()]
    if not check:
        for d in FOLDERS:
            (BUSINESS_DIR / d).mkdir(parents=True, exist_ok=True)
    for target, source in TEMPLATES.items():
        path = BUSINESS_DIR / target
        wanted = read(HERE / "compartido" / source) + "\n"
        if path.is_file() and path.read_text(encoding="utf-8") == wanted:
            continue
        changes.append(target)
        if not check:
            path.write_text(wanted, encoding="utf-8")
    return {"agente": "carpeta compartida", "estado": ("cambiaría: " if check else "cambiado: ") + ", ".join(changes)
            if changes else "sin cambios", "resultado": {"ok": True}}


def soul(name: str) -> str:
    """A specialist's own role, then what the whole team shares."""
    return read(HERE / "agentes" / f"{name}.md") + "\n\n" + read(HERE / "compartido" / "equipo.md")


def lead_block() -> str:
    return "\n\n".join([BLOCK_START, read(HERE / "lider" / f"{LEAD}.md"),
                        read(HERE / "compartido" / "equipo.md"), BLOCK_END])


def with_block(text: str, block: str) -> str:
    """The lead's instructions with the team section in place: replaced between
    its markers, else put before the message style guide, else at the end."""
    if BLOCK_START in text and BLOCK_END in text:
        head, rest = text.split(BLOCK_START, 1)
        return head + block + rest.split(BLOCK_END, 1)[1]
    if STYLE_START in text:
        head, rest = text.split(STYLE_START, 1)
        return head.rstrip() + "\n\n" + block + "\n\n" + STYLE_START + rest
    return text.rstrip() + "\n\n" + block + "\n"


def set_alice_placement(profile_dir: Path, section, order: int, check: bool = False) -> bool:
    """Where Alice files the agent (`ui_meta['alice']`), merged the way Hermes
    stores ui_meta: other namespaces untouched, this one's revision bumped.
    Written only when it changes, so Alice does not place the agent again."""
    import tui_gateway.methods_profiles as profiles_rpc
    from utils import atomic_yaml_write
    existing = profiles_rpc._read_profile_yaml(profile_dir)
    current = existing.get("ui_meta") if isinstance(existing.get("ui_meta"), dict) else {}
    placement = {"channel": CHANNEL, "order": order}
    if section:
        placement["section"] = section
    placement["sections"] = DEPARTMENTS
    if current.get("alice") == placement:
        return False
    if check:
        return True
    raw = existing.get("_ui_meta_revisions")
    revisions = profiles_rpc._clean_revisions(raw if isinstance(raw, dict) else {})
    current["alice"] = placement
    revisions["alice"] = revisions.get("alice", 0) + 1
    existing["ui_meta"] = current
    existing["_ui_meta_revisions"] = revisions
    atomic_yaml_write(profile_dir / "profile.yaml", existing, sort_keys=False)
    return True


def hide_sandbox(profile_dir: Path, check: bool) -> bool:
    """The sandbox under Hidden in Alice, with a name that says what it is."""
    import tui_gateway.methods_profiles as profiles_rpc
    from utils import atomic_yaml_write
    existing = profiles_rpc._read_profile_yaml(profile_dir)
    meta = existing.get("ui_meta") if isinstance(existing.get("ui_meta"), dict) else {}
    bots = dict(meta.get("hermes-bots") or {})
    if bots.get("hidden") is True and bots.get("title") == SANDBOX_TITLE:
        return False
    if check:
        return True
    raw = existing.get("_ui_meta_revisions")
    revisions = profiles_rpc._clean_revisions(raw if isinstance(raw, dict) else {})
    bots.update({"hidden": True, "title": SANDBOX_TITLE})
    meta["hermes-bots"] = bots
    revisions["hermes-bots"] = revisions.get("hermes-bots", 0) + 1
    existing["ui_meta"] = meta
    existing["_ui_meta_revisions"] = revisions
    atomic_yaml_write(profile_dir / "profile.yaml", existing, sort_keys=False)
    return True


def prepare_evals(check: bool) -> dict:
    """The evals harness in its stable place and the sandbox profile that every
    evaluation runs in. The sandbox is a clone of Alice's profile (config, keys and
    skills, never messaging channels) that evals.py re-syncs before each run."""
    from hermes_cli.profiles import get_profile_dir
    from crear_agente import hermes
    changes = []
    wanted = EVALS_SOURCE.read_text(encoding="utf-8")
    if not EVALS_TOOL.is_file() or EVALS_TOOL.read_text(encoding="utf-8") != wanted:
        changes.append("herramienta")
        if not check:
            EVALS_TOOL.parent.mkdir(parents=True, exist_ok=True)
            EVALS_TOOL.write_text(wanted, encoding="utf-8")
    sandbox_dir = Path(get_profile_dir(SANDBOX))
    if not sandbox_dir.is_dir():
        changes.append("perfil de pruebas")
        if not check:
            hermes("profile", "create", SANDBOX, "--clone-from", "default", "--no-alias",
                   "--description", SANDBOX_DESCRIPTION)
    if sandbox_dir.is_dir() and hide_sandbox(sandbox_dir, check):
        changes.append("oculto en Alice")
    return {"agente": "evals · herramienta y pruebas", "estado": ("cambiaría: " if check else "cambiado: ") + ", ".join(changes)
            if changes else "sin cambios", "resultado": {"ok": True}}


def enable_isolation(check: bool) -> dict:
    """The Alice plugin, whose hook keeps Business talking only among itself, enabled in
    every profile: the hook runs in the sender's own process, so a profile without it
    could still reach the team."""
    from crear_agente import hermes
    import re
    # Only real profiles: Hermes keeps deleted ones in `.deleted` and a half-removed
    # profile has no config to enable anything in.
    homes = [("default", HERMES_ROOT.parent)] + sorted(
        (p.name, p) for p in (HERMES_ROOT.parent / "profiles").iterdir()
        if p.is_dir() and re.fullmatch(r"[a-z0-9][a-z0-9-]*", p.name) and (p / "config.yaml").is_file())
    changed = []
    for name, home in homes:
        cfg = _load_yaml(home / "config.yaml")
        enabled = ((cfg.get("plugins") or {}).get("enabled")) or []
        if "alice" in enabled:
            continue
        changed.append(name)
        if not check:
            prefix = [] if name == "default" else ["-p", name]
            hermes(*prefix, "plugins", "enable", "alice", "--no-allow-tool-override")
    return {"agente": "aislamiento de Business", "estado": ("cambiaría: " if check else "plugin activado en: ")
            + ", ".join(changed) if changed else "sin cambios", "resultado": {"ok": True}}


def _load_yaml(path: Path) -> dict:
    import yaml
    if not path.is_file():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return data if isinstance(data, dict) else {}


def install_lead(check: bool) -> dict:
    from hermes_cli.profiles import get_profile_dir
    profile_dir = Path(get_profile_dir(LEAD))
    soul_path = profile_dir / "SOUL.md"
    if not soul_path.is_file():
        return {"agente": LEAD, "resultado": {"ok": False, "error": f"No existe el agente `{LEAD}`."}}
    text = soul_path.read_text(encoding="utf-8")
    new = with_block(text, lead_block())
    instructions = new != text
    if instructions and not check:
        soul_path.write_text(new, encoding="utf-8")
    placed = set_alice_placement(profile_dir, None, 0, check)
    changes = [c for c, changed in (("instrucciones", instructions), ("sitio_en_alice", placed)) if changed]
    return {"agente": LEAD, "estado": ("cambiaría: " if check else "cambiado: ") + ", ".join(changes)
            if changes else "sin cambios", "resultado": {"ok": True}}


def update_specialist(member: dict, profile_dir: Path) -> None:
    import tui_gateway.methods_profiles as profiles_rpc
    from utils import atomic_yaml_write
    from crear_agente import with_style
    (profile_dir / "SOUL.md").write_text(with_style(soul(member["name"])) + "\n", encoding="utf-8")
    existing = profiles_rpc._read_profile_yaml(profile_dir)
    if existing.get("description") != member["description"]:
        existing["description"] = member["description"]
        atomic_yaml_write(profile_dir / "profile.yaml", existing, sort_keys=False)


def sync_profile(member: dict, profile_dir: Path, check: bool) -> list:
    """What the team needs from a specialist that already exists: its visible
    name, its extra tools and its config. Tools are only added, never removed."""
    import yaml
    import tui_gateway.methods_profiles as profiles_rpc
    from utils import atomic_yaml_write
    from crear_agente import hermes
    changes = []
    cfg = yaml.safe_load((profile_dir / "config.yaml").read_text(encoding="utf-8")) or {}

    tools = list(((cfg.get("platform_toolsets") or {}).get("cli")) or [])
    missing = [t for t in member["tools"] if t not in tools]
    if missing:
        changes.append("herramientas +" + ",".join(missing))
        if not check:
            hermes("-p", member["name"], "config", "set", "platform_toolsets.cli", json.dumps(tools + missing))

    for key, value in (member.get("config") or {}).items():
        current = cfg
        for part in key.split("."):
            current = current.get(part) if isinstance(current, dict) else None
        if current != value:
            changes.append(key)
            if not check:
                hermes("-p", member["name"], "config", "set", key, value if isinstance(value, str) else json.dumps(value))

    existing = profiles_rpc._read_profile_yaml(profile_dir)
    meta = existing.get("ui_meta") if isinstance(existing.get("ui_meta"), dict) else {}
    bots = dict(meta.get("hermes-bots") or {})
    if bots.get("title") != member["title"]:
        changes.append("nombre")
        if not check:
            raw = existing.get("_ui_meta_revisions")
            revisions = profiles_rpc._clean_revisions(raw if isinstance(raw, dict) else {})
            bots["title"] = member["title"]
            meta["hermes-bots"] = bots
            revisions["hermes-bots"] = revisions.get("hermes-bots", 0) + 1
            existing["ui_meta"] = meta
            existing["_ui_meta_revisions"] = revisions
            atomic_yaml_write(profile_dir / "profile.yaml", existing, sort_keys=False)
    return changes


def install_specialist(member: dict, order: int, check: bool, refresh: bool) -> dict:
    from hermes_cli.profiles import get_profile_dir
    profile_dir = Path(get_profile_dir(member["name"]))
    if profile_dir.exists():
        if refresh and not check:
            update_specialist(member, profile_dir)
        placed = set_alice_placement(profile_dir, member.get("department"), order, check)
        synced = sync_profile(member, profile_dir, check)
        state = "actualizado" if refresh else "ya existe"
        if check:
            state = "ya existe" + (" (se actualizaría)" if refresh else "")
        extras = (["sitio en Alice"] if placed else []) + synced
        return {"agente": member["name"], "estado": state + "".join(" · " + e for e in extras),
                "resultado": {"ok": True}}

    spec = {"name": member["name"], "title": member["title"], "description": member["description"],
            "soul": soul(member["name"]), "tools": member["tools"],
            "routines": member.get("routines", [])}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as handle:
        json.dump(spec, handle, ensure_ascii=False)
        spec_path = handle.name
    try:
        command = [sys.executable, str(FORJA_SCRIPTS / "crear_agente.py"), spec_path, "--sin-atajo"]
        if check:
            command.append("--comprobar")
        run = subprocess.run(command, capture_output=True, text=True, timeout=900)
    finally:
        Path(spec_path).unlink(missing_ok=True)
    try:
        created = json.loads(run.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        created = {"ok": False, "error": (run.stderr or run.stdout).strip()[-400:]}
    if created.get("ok") and not check:
        set_alice_placement(profile_dir, member.get("department"), order)
        sync_profile(member, profile_dir, check)
    return {"agente": member["name"], "estado": "comprobado" if check else "creado", "resultado": created}


def main(argv: list) -> int:
    check = "--comprobar" in argv
    refresh = "--actualizar" in argv
    results = [prepare_shared_folder(check), prepare_evals(check), install_lead(check),
               install_specialist(EVALS, 1, check, refresh)]
    # Last: a profile created above must get the hook too.
    finals = [enable_isolation]
    by_department = sorted(TEAM, key=lambda m: DEPARTMENTS.index(m["department"]))
    for order, member in enumerate(by_department, start=2):
        results.append(install_specialist(member, order, check, refresh))
    results += [step(check) for step in finals]
    ok = all(r["resultado"].get("ok", False) for r in results)
    print(json.dumps({"ok": ok, "canal": CHANNEL, "equipo": results}, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
