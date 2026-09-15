#!/usr/bin/env python3
"""Instala el equipo de Business en el Hermes de este Mac.

Con el Python de Hermes:

    ~/.hermes/hermes-agent/venv/bin/python instalar.py [--comprobar] [--actualizar]

Crea los siete agentes con la herramienta de Forja (modelo estándar con reserva,
herramientas con la de preguntas, instrucciones con la guía de estilo y nombre
visible) y le dice a Alice en qué canal y sección aparece cada uno. Nunca borra
agentes. Un agente del equipo que ya existe se deja como está, salvo con
--actualizar: entonces se reescriben solo sus instrucciones, su descripción y su
sitio en Alice; su modelo y sus herramientas no se tocan. Imprime un JSON.
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
SECTION = "Especialistas"

TEAM = [
    {"name": "biz-director", "title": "Director", "section": None, "tools": ["session_search", "cronjob"],
     "description": "Punto de entrada del equipo de Business: convierte tu objetivo en plan, reparte el trabajo, integra y decide el siguiente paso."},
    {"name": "biz-mercado", "title": "Mercado", "section": SECTION, "tools": ["browser"],
     "description": "Clientes, demanda y competencia con fuentes verificables para validar o descartar ideas rápido."},
    {"name": "biz-producto", "title": "Producto", "section": SECTION, "tools": ["browser"],
     "description": "Propuesta de valor, MVP mínimo y experiencia de usuario que hace volver."},
    {"name": "biz-growth", "title": "Growth", "section": SECTION, "tools": ["browser"],
     "description": "Posicionamiento, mensajes, canales y experimentos para conseguir clientes al menor coste."},
    {"name": "biz-ingresos", "title": "Ingresos", "section": SECTION, "tools": ["code_execution"],
     "description": "Modelo de negocio, precios, ventas y números: CAC, LTV, márgenes y escenarios."},
    {"name": "biz-tech", "title": "Tecnología", "section": SECTION, "tools": ["terminal", "code_execution", "browser"],
     "description": "Construir o comprar, stack, automatización, estimaciones y seguridad sin sobreingeniería."},
    {"name": "biz-critico", "title": "Abogado del diablo", "section": SECTION, "tools": ["browser"],
     "description": "Pre-mortem, supuestos, riesgos, legal y verificación antes de apostar tiempo o dinero."},
]


def soul(name: str) -> str:
    """The agent's own role, then what the whole team shares."""
    parts = [HERE / "agentes" / f"{name}.md", HERE / "compartido" / "equipo.md"]
    return "\n\n".join(p.read_text(encoding="utf-8").strip() for p in parts)


def set_alice_placement(profile_dir: Path, channel: str, section, order: int) -> None:
    """Where Alice files the agent (`ui_meta['alice']`), merged the way Hermes
    stores ui_meta: other namespaces untouched, this one's revision bumped."""
    import tui_gateway.methods_profiles as profiles_rpc
    from utils import atomic_yaml_write
    existing = profiles_rpc._read_profile_yaml(profile_dir)
    raw = existing.get("_ui_meta_revisions")
    revisions = profiles_rpc._clean_revisions(raw if isinstance(raw, dict) else {})
    current = existing.get("ui_meta") if isinstance(existing.get("ui_meta"), dict) else {}
    placement = {"channel": channel, "order": order}
    if section:
        placement["section"] = section
    current["alice"] = placement
    revisions["alice"] = revisions.get("alice", 0) + 1
    existing["ui_meta"] = current
    existing["_ui_meta_revisions"] = revisions
    atomic_yaml_write(profile_dir / "profile.yaml", existing, sort_keys=False)


def update_existing(member: dict, profile_dir: Path, order: int) -> None:
    import tui_gateway.methods_profiles as profiles_rpc
    from utils import atomic_yaml_write
    from crear_agente import with_style
    (profile_dir / "SOUL.md").write_text(with_style(soul(member["name"])) + "\n", encoding="utf-8")
    existing = profiles_rpc._read_profile_yaml(profile_dir)
    existing["description"] = member["description"]
    atomic_yaml_write(profile_dir / "profile.yaml", existing, sort_keys=False)
    set_alice_placement(profile_dir, CHANNEL, member["section"], order)


def main(argv: list) -> int:
    check = "--comprobar" in argv
    refresh = "--actualizar" in argv
    from hermes_cli.profiles import get_profile_dir
    results = []
    for order, member in enumerate(TEAM):
        profile_dir = Path(get_profile_dir(member["name"]))
        if profile_dir.exists():
            if refresh and not check:
                update_existing(member, profile_dir, order)
                results.append({"agente": member["name"], "estado": "actualizado"})
            else:
                results.append({"agente": member["name"], "estado": "ya existe" + (" (se actualizaría)" if refresh else "")})
            continue
        spec = {"name": member["name"], "title": member["title"], "description": member["description"],
                "soul": soul(member["name"]), "tools": member["tools"], "routines": []}
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
            set_alice_placement(profile_dir, CHANNEL, member["section"], order)
        results.append({"agente": member["name"], "estado": "comprobado" if check else "creado",
                        "resultado": created})
    ok = all(r.get("resultado", {"ok": True}).get("ok", False) for r in results)
    print(json.dumps({"ok": ok, "canal": CHANNEL, "equipo": results}, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
