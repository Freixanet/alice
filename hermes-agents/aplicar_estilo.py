#!/usr/bin/env python3
"""Pone la guía de estilo de mensajes de Alice en las instrucciones de todos los
agentes de este Hermes y en las de Alice.

    python3 aplicar_estilo.py [--comprobar]

La guía vive en forja/skill/forja-crear-agentes/references/estilo-mensajes.md y
va entre marcadores: si un agente ya la tiene, se sustituye por la versión
actual; si no, se añade al final. Nada más de las instrucciones cambia. La guía
cede ante cualquier formato exacto que fijen las instrucciones del agente.
Respeta HERMES_HOME. Imprime un JSON con lo que cambió.
"""
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STYLE = HERE / "forja" / "skill" / "forja-crear-agentes" / "references" / "estilo-mensajes.md"
START = "<!-- alice:estilo inicio -->"
END = "<!-- alice:estilo fin -->"


def styled(text: str, block: str) -> str:
    if START in text and END in text:
        head, rest = text.split(START, 1)
        tail = rest.split(END, 1)[1]
        return head + block + tail
    return text.rstrip() + "\n\n" + block + "\n"


def main(argv: list) -> int:
    check = "--comprobar" in argv
    block = STYLE.read_text(encoding="utf-8").strip()
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    souls = [home / "SOUL.md"] + sorted((home / "profiles").glob("*/SOUL.md"))
    changed, unchanged = [], []
    for path in souls:
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        new = styled(text, block)
        name = "alice" if path.parent == home else path.parent.name
        if new == text:
            unchanged.append(name)
            continue
        if not check:
            path.write_text(new, encoding="utf-8")
        changed.append(name)
    print(json.dumps({"ok": True, "comprobacion": check, "cambian": changed, "sin_cambios": unchanged},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
