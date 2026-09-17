#!/usr/bin/env python3
"""CLI for Agent Maker: validates a spec and calls the shared Alice engine.

    python crear_agente.py especificacion.json [--comprobar] [--sin-atajo] [--sin-humo]

The engine lives in the Alice plugin (`agent_engine.py`). This script locates
it, adds the message-style guide, and keeps the previous command-line shape.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STYLE = HERE.parent / "references" / "estilo-mensajes.md"


def _load_engine():
    candidates = [HERE]
    for parent in Path(__file__).resolve().parents:
        plugin = parent / "hermes-plugin"
        if (plugin / "agent_engine.py").is_file():
            candidates.append(plugin)
            break
    home = Path(__import__("os").environ.get("HERMES_HOME") or Path.home() / ".hermes")
    candidates.append(home / "plugins" / "alice")
    for path in candidates:
        if (path / "agent_engine.py").is_file():
            if str(path) not in sys.path:
                sys.path.insert(0, str(path))
            import agent_engine
            return agent_engine
    raise RuntimeError("agent_engine.py was not found next to this script or in the Alice plugin.")


engine = _load_engine()
SpecError = engine.SpecError
has_examples = engine.has_examples
with_style = lambda soul: engine.with_style(soul, STYLE if STYLE.is_file() else None)
load_spec = lambda path: engine.load_spec(path, style_file=STYLE if STYLE.is_file() else None)


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1:
        print(json.dumps({
            "ok": False,
            "status": engine.STATUS_FAILED,
            "error": "Uso: crear_agente.py especificacion.json [--comprobar] [--sin-atajo] [--sin-humo]",
        }, ensure_ascii=False))
        return 2
    try:
        spec = json.loads(Path(args[0]).read_text(encoding="utf-8"))
        if not isinstance(spec, dict):
            raise SpecError("La especificación debe ser un objeto JSON.")
        spec = dict(spec)
        spec["source"] = spec.get("source") or "maker"
        spec["smoke"] = "--sin-humo" not in flags
        payload = engine.create_agent(
            spec,
            style_file=STYLE if STYLE.is_file() else None,
            dry_run="--comprobar" in flags,
            no_alias="--sin-atajo" in flags,
            require_soul=True,
        )
        if "--comprobar" in flags:
            payload["comprobacion"] = True
    except SpecError as exc:
        payload = engine.result(engine.STATUS_FAILED, error=str(exc))
    except Exception as exc:
        payload = engine.result(engine.STATUS_FAILED, error=str(exc))
    # Keep the previous key so Agent Maker's spoken summary still reads.
    if payload.get("confirmed") and "hecho" not in payload:
        payload["hecho"] = payload["confirmed"]
    if payload.get("checks") and "comprobaciones" not in payload:
        payload["comprobaciones"] = payload["checks"]
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
