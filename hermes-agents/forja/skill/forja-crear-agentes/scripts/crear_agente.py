#!/usr/bin/env python3
"""Crea un agente de Hermes completo a partir de una especificación JSON.

Uso, con el Python de Hermes:

    ~/.hermes/hermes-agent/venv/bin/python crear_agente.py especificacion.json [--comprobar] [--sin-atajo]

Crea el perfil con los comandos oficiales de Hermes (habilidades incluidas y
atajo de terminal), le pone el modelo estándar con reserva, las herramientas
(siempre con la de preguntas), sus instrucciones, su nombre visible en Alice y
sus rutinas; después lo comprueba todo. Nunca modifica ni borra un perfil que
ya exista. Imprime un JSON con el resultado.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERMES_ROOT = Path.home() / ".hermes" / "hermes-agent"
HERMES_BIN = HERMES_ROOT / "venv" / "bin" / "hermes"
sys.path.insert(0, str(HERMES_ROOT))

MODEL = {"default": "muse-spark-1.3-contributor-free", "provider": "opencode-free", "base_url": ""}
FALLBACK = [{"provider": "openai-codex", "model": "gpt-5.6-luna",
             "base_url": "https://chatgpt.com/backend-api/codex"}]
BASE_TOOLS = ["web", "file", "skills", "memory", "clarify", "todo"]
EXTRA_TOOLS = {"browser", "terminal", "code_execution", "vision", "image_gen", "tts",
               "session_search", "cronjob", "delegation"}
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
# The message style every agent follows in Alice. One copy, beside this script,
# so an agent Forja creates writes like the rest.
STYLE = Path(__file__).resolve().parent.parent / "references" / "estilo-mensajes.md"
STYLE_START = "<!-- alice:estilo inicio -->"


def after_title(text: str, block: str) -> str:
    lines = text.splitlines(keepends=True)
    insert = 0
    for i, line in enumerate(lines):
        if line.lstrip().startswith("# "):
            insert = i + 1
            if insert < len(lines) and lines[insert].strip() == "":
                insert += 1
            break
    return "".join(lines[:insert]) + block.strip() + "\n\n" + "".join(lines[insert:])


def with_style(soul: str) -> str:
    """The instructions with the message style after the title, unless they carry it."""
    if STYLE_START in soul or not STYLE.is_file():
        return soul
    return after_title(soul, STYLE.read_text(encoding="utf-8"))


class SpecError(ValueError):
    pass


def load_spec(path: Path) -> dict:
    try:
        spec = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SpecError(f"No se pudo leer la especificación: {exc}") from exc
    if not isinstance(spec, dict):
        raise SpecError("La especificación debe ser un objeto JSON.")
    name = str(spec.get("name") or "").strip()
    if not NAME.match(name):
        raise SpecError("`name` debe tener 2-40 caracteres: minúsculas, números y guiones.")
    for key in ("title", "description", "soul"):
        if not str(spec.get(key) or "").strip():
            raise SpecError(f"Falta `{key}`.")
    tools = spec.get("tools") or []
    if not isinstance(tools, list) or any(t not in EXTRA_TOOLS for t in tools):
        raise SpecError(f"`tools` solo admite: {', '.join(sorted(EXTRA_TOOLS))}.")
    routines = spec.get("routines") or []
    if not isinstance(routines, list):
        raise SpecError("`routines` debe ser una lista.")
    for routine in routines:
        if not isinstance(routine, dict) or not all(str(routine.get(k) or "").strip()
                                                    for k in ("name", "schedule", "prompt")):
            raise SpecError("Cada rutina necesita `name`, `schedule` y `prompt`.")
    return {
        "name": name,
        "title": str(spec["title"]).strip(),
        "description": str(spec["description"]).strip(),
        "soul": with_style(str(spec["soul"]).strip()) + "\n",
        "tools": BASE_TOOLS + [t for t in tools if t not in BASE_TOOLS],
        "routines": routines,
    }


def hermes(*args: str, timeout: int = 300) -> str:
    result = subprocess.run([str(HERMES_BIN), *args], capture_output=True, text=True,
                            timeout=timeout, env=os.environ.copy())
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()[-3:]
        raise RuntimeError(f"`hermes {args[0]} {args[1] if len(args) > 1 else ''}` falló: {' '.join(detail)}")
    return result.stdout


def set_visible_name(profile_dir: Path, title: str) -> None:
    """El nombre que Alice muestra (ui_meta de Hermes Bot Mode), con el mismo
    formato que guarda Hermes: fusión por clave y revisión incrementada."""
    import tui_gateway.methods_profiles as profiles_rpc
    from utils import atomic_yaml_write
    existing = profiles_rpc._read_profile_yaml(profile_dir)
    raw = existing.get("_ui_meta_revisions")
    revisions = profiles_rpc._clean_revisions(raw if isinstance(raw, dict) else {})
    current = existing.get("ui_meta") if isinstance(existing.get("ui_meta"), dict) else {}
    bots = dict(current.get("hermes-bots") or {})
    bots.update({"title": title, "created": time.time() * 1000, "shape": "blobatar", "imageKind": "shape"})
    current["hermes-bots"] = bots
    revisions["hermes-bots"] = revisions.get("hermes-bots", 0) + 1
    existing["ui_meta"] = current
    existing["_ui_meta_revisions"] = revisions
    atomic_yaml_write(profile_dir / "profile.yaml", existing, sort_keys=False)


def verify(spec: dict, profile_dir: Path) -> dict:
    import yaml
    import tui_gateway.methods_profiles as profiles_rpc
    from hermes_cli.tools_config import _get_platform_tools
    cfg = yaml.safe_load((profile_dir / "config.yaml").read_text(encoding="utf-8")) or {}
    row: dict = {}
    profiles_rpc._profile_ui_meta_fields(row, profile_dir)
    title = (row.get("ui_meta") or {}).get("hermes-bots", {}).get("title")
    tools = _get_platform_tools(cfg, "cli", include_default_mcp_servers=False)
    jobs_file = profile_dir / "cron" / "jobs.json"
    jobs = []
    if jobs_file.exists():
        data = json.loads(jobs_file.read_text(encoding="utf-8"))
        jobs = data.get("jobs", data) if isinstance(data, dict) else data
    return {
        "perfil_creado": profile_dir.is_dir(),
        "instrucciones": (profile_dir / "SOUL.md").is_file(),
        "nombre_visible": title == spec["title"],
        "modelo": (cfg.get("model") or {}).get("default") == MODEL["default"],
        "reserva": [f.get("model") for f in cfg.get("fallback_providers") or []] == [FALLBACK[0]["model"]],
        "herramienta_preguntas": "clarify" in tools,
        "rutinas": len(jobs) >= len(spec["routines"]),
    }


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1:
        print(json.dumps({"ok": False, "error": "Uso: crear_agente.py especificacion.json [--comprobar] [--sin-atajo]"},
                         ensure_ascii=False))
        return 2
    try:
        spec = load_spec(Path(args[0]))
        from hermes_cli.profiles import get_profile_dir
        profile_dir = Path(get_profile_dir(spec["name"]))
        if profile_dir.exists():
            raise SpecError(f"Ya existe un agente llamado `{spec['name']}`. Elige otro nombre.")
    except SpecError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1

    plan = {"name": spec["name"], "title": spec["title"], "tools": spec["tools"],
            "routines": [r["name"] for r in spec["routines"]], "path": str(profile_dir)}
    if "--comprobar" in flags:
        print(json.dumps({"ok": True, "comprobacion": True, "plan": plan}, ensure_ascii=False))
        return 0

    done: list[str] = []
    try:
        create = ["profile", "create", spec["name"], "--description", spec["description"]]
        if "--sin-atajo" in flags:
            create.append("--no-alias")
        hermes(*create)
        done.append("perfil")
        for key in ("default", "provider", "base_url"):
            hermes("-p", spec["name"], "config", "set", f"model.{key}", MODEL[key])
        hermes("-p", spec["name"], "config", "set", "fallback_providers", json.dumps(FALLBACK))
        hermes("-p", spec["name"], "config", "set", "platform_toolsets.cli", json.dumps(spec["tools"]))
        done.append("configuracion")
        (profile_dir / "SOUL.md").write_text(spec["soul"], encoding="utf-8")
        done.append("instrucciones")
        set_visible_name(profile_dir, spec["title"])
        done.append("nombre_visible")
        for routine in spec["routines"]:
            hermes("-p", spec["name"], "cron", "create", str(routine["schedule"]), str(routine["prompt"]),
                   "--name", str(routine["name"]), "--deliver", "bot-chat")
        if spec["routines"]:
            done.append("rutinas")
        checks = verify(spec, profile_dir)
    except Exception as exc:  # report exactly what was done; never delete
        print(json.dumps({"ok": False, "hecho": done, "error": str(exc), "plan": plan}, ensure_ascii=False))
        return 1

    ok = all(checks.values())
    print(json.dumps({"ok": ok, "hecho": done, "comprobaciones": checks, "plan": plan}, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
