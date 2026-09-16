#!/usr/bin/env python3
"""Crea un agente de Hermes completo a partir de una especificación JSON.

Uso, con el Python de Hermes:

    python crear_agente.py especificacion.json [--comprobar] [--sin-atajo] [--sin-humo]

Crea el perfil con los comandos oficiales de Hermes (habilidades incluidas y
atajo de terminal), le pone el modelo estándar con reserva, las herramientas
(siempre con la de preguntas), sus instrucciones, su nombre visible en Alice y
sus rutinas; después lo comprueba y hace una prueba de humo. Nunca modifica ni
borra un perfil que ya exista. Imprime un JSON con el resultado.

Rutas y modelos (por si este Hermes no es ~/.hermes ni usa Muse Spark):

    HERMES_HOME, HERMES_BIN, ALICE_AGENT_MODEL, ALICE_AGENT_FALLBACK
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

NAME = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
EXAMPLES = re.compile(r"^##\s+(Ejemplos|Examples)\s*$", re.I | re.M)
STYLE = Path(__file__).resolve().parent.parent / "references" / "estilo-mensajes.md"
STYLE_START = "<!-- alice:estilo inicio -->"
BASE_TOOLS = ["web", "file", "skills", "memory", "clarify", "todo"]
EXTRA_TOOLS = {"browser", "terminal", "code_execution", "vision", "image_gen", "tts",
               "session_search", "cronjob", "delegation"}
DEFAULT_MODEL = {"default": "muse-spark-1.3-contributor-free", "provider": "opencode-free", "base_url": ""}
DEFAULT_FALLBACK = [{"provider": "openai-codex", "model": "gpt-5.6-luna",
                     "base_url": "https://chatgpt.com/backend-api/codex"}]
SMOKE_PROMPT = "Reply with exactly OK and nothing else."


def hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def hermes_agent_root() -> Path:
    return Path(os.environ.get("HERMES_AGENT") or hermes_home() / "hermes-agent")


def hermes_bin() -> Path:
    return Path(os.environ.get("HERMES_BIN") or hermes_agent_root() / "venv" / "bin" / "hermes")


def model_config() -> dict:
    raw = os.environ.get("ALICE_AGENT_MODEL")
    if raw:
        value = json.loads(raw)
        if not isinstance(value, dict) or "default" not in value:
            raise SpecError("ALICE_AGENT_MODEL must be a JSON object with `default`.")
        return {
            "default": str(value["default"]),
            "provider": str(value.get("provider") or ""),
            "base_url": str(value.get("base_url") or ""),
        }
    return dict(DEFAULT_MODEL)


def fallback_config() -> list:
    raw = os.environ.get("ALICE_AGENT_FALLBACK")
    if raw:
        value = json.loads(raw)
        if not isinstance(value, list) or not value:
            raise SpecError("ALICE_AGENT_FALLBACK must be a JSON array.")
        return value
    return list(DEFAULT_FALLBACK)


def profile_dir_for(name: str) -> Path:
    return hermes_home() / "profiles" / name


def has_examples(soul: str) -> bool:
    match = EXAMPLES.search(soul)
    if not match:
        return False
    rest = soul[match.end():]
    nxt = re.search(r"^##\s+", rest, re.M)
    body = rest[:nxt.start()] if nxt else rest
    return len(body.strip()) >= 40


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
    soul = str(spec["soul"]).strip()
    if not has_examples(soul):
        raise SpecError("`soul` debe incluir una sección `## Ejemplos` o `## Examples` con turnos de ejemplo.")
    tools = spec.get("tools") or []
    if not isinstance(tools, list):
        raise SpecError("`tools` debe ser una lista.")
    allowed = EXTRA_TOOLS | set(BASE_TOOLS)
    if any(t not in allowed for t in tools):
        raise SpecError(f"`tools` solo admite extras: {', '.join(sorted(EXTRA_TOOLS))}.")
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
        "soul": with_style(soul) + "\n",
        "tools": BASE_TOOLS + [t for t in tools if t not in BASE_TOOLS],
        "routines": routines,
        "model": model_config(),
        "fallback": fallback_config(),
    }


def hermes(*args: str, timeout: int = 300) -> str:
    result = subprocess.run(
        [str(hermes_bin()), *args], capture_output=True, text=True,
        timeout=timeout, env=os.environ.copy(),
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()[-3:]
        raise RuntimeError(f"`hermes {args[0] if args else ''}` falló: {' '.join(detail)}")
    return result.stdout


def _read_mapping(path: Path) -> dict:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    try:
        import yaml
        data = yaml.safe_load(text)
        return data if isinstance(data, dict) else {}
    except Exception:
        try:
            data = json.loads(text)
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}


def _write_mapping(path: Path, data: dict) -> None:
    try:
        sys.path.insert(0, str(hermes_agent_root()))
        from utils import atomic_yaml_write
        atomic_yaml_write(path, data, sort_keys=False)
        return
    except Exception:
        pass
    try:
        import yaml
        path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
    except Exception:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def set_visible_name(profile_dir: Path, title: str) -> None:
    """El nombre que Alice muestra (ui_meta de Hermes Bot Mode)."""
    path = profile_dir / "profile.yaml"
    existing = _read_mapping(path)
    current = existing.get("ui_meta") if isinstance(existing.get("ui_meta"), dict) else {}
    bots = dict(current.get("hermes-bots") or {})
    bots.update({"title": title, "created": time.time() * 1000, "shape": "blobatar", "imageKind": "shape"})
    current["hermes-bots"] = bots
    revisions = existing.get("_ui_meta_revisions") if isinstance(existing.get("_ui_meta_revisions"), dict) else {}
    revisions["hermes-bots"] = int(revisions.get("hermes-bots") or 0) + 1
    existing["ui_meta"] = current
    existing["_ui_meta_revisions"] = revisions
    _write_mapping(path, existing)


def visible_title(profile_dir: Path) -> str | None:
    meta = _read_mapping(profile_dir / "profile.yaml")
    bots = ((meta.get("ui_meta") or {}).get("hermes-bots") or {})
    title = bots.get("title") if isinstance(bots, dict) else None
    return str(title) if title else None


def smoke(name: str) -> bool:
    """Una pregunta mínima. No es una evaluación; solo comprueba que responde."""
    out = hermes("-p", name, "-z", SMOKE_PROMPT, timeout=120)
    return "OK" in out.upper()


def verify(spec: dict, profile_dir: Path, smoked: bool | None) -> dict:
    cfg = _read_mapping(profile_dir / "config.yaml")
    model = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
    fallback = cfg.get("fallback_providers") or []
    tools = (cfg.get("platform_toolsets") or {}).get("cli") or []
    if isinstance(tools, str):
        try:
            tools = json.loads(tools)
        except ValueError:
            tools = [tools]
    jobs_file = profile_dir / "cron" / "jobs.json"
    jobs = []
    if jobs_file.exists():
        data = json.loads(jobs_file.read_text(encoding="utf-8"))
        jobs = data.get("jobs", data) if isinstance(data, dict) else data
    soul = (profile_dir / "SOUL.md").read_text(encoding="utf-8") if (profile_dir / "SOUL.md").is_file() else ""
    checks = {
        "perfil_creado": profile_dir.is_dir(),
        "instrucciones": bool(soul),
        "ejemplos": has_examples(soul),
        "nombre_visible": visible_title(profile_dir) == spec["title"],
        "modelo": model.get("default") == spec["model"]["default"],
        "reserva": [f.get("model") for f in fallback] == [spec["fallback"][0].get("model")],
        "herramienta_preguntas": "clarify" in tools,
        "rutinas": len(jobs) >= len(spec["routines"]),
    }
    if smoked is not None:
        checks["humo"] = smoked
    return checks


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1:
        print(json.dumps({
            "ok": False,
            "error": "Uso: crear_agente.py especificacion.json [--comprobar] [--sin-atajo] [--sin-humo]",
        }, ensure_ascii=False))
        return 2
    try:
        spec = load_spec(Path(args[0]))
        profile_dir = profile_dir_for(spec["name"])
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
    smoked: bool | None = None
    try:
        create = ["profile", "create", spec["name"], "--description", spec["description"]]
        if "--sin-atajo" in flags:
            create.append("--no-alias")
        hermes(*create)
        done.append("perfil")
        model = spec["model"]
        for key in ("default", "provider", "base_url"):
            hermes("-p", spec["name"], "config", "set", f"model.{key}", model[key])
        hermes("-p", spec["name"], "config", "set", "fallback_providers", json.dumps(spec["fallback"]))
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
        if "--sin-humo" not in flags:
            smoked = smoke(spec["name"])
            done.append("humo")
        checks = verify(spec, profile_dir, smoked)
    except Exception as exc:  # report exactly what was done; never delete
        print(json.dumps({"ok": False, "hecho": done, "error": str(exc), "plan": plan},
                         ensure_ascii=False))
        return 1

    ok = all(checks.values())
    print(json.dumps({"ok": ok, "hecho": done, "comprobaciones": checks, "plan": plan},
                     ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
