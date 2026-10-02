#!/usr/bin/env python3
"""Pone la personalidad de Alice en sus instrucciones (~/.hermes/SOUL.md).

    python3 hermes-agents/alice/instalar.py [--nombre NOMBRE] [--comprobar]

El nombre de la persona sale de ``--nombre`` o, si no se da, del que Alice ya guarda en
sus datos (Ajustes › Datos personales); sin ninguno no instala nada y lo dice.

La personalidad va entre marcadores, después de la guía de estilo y antes del
bloque de proactividad. La primera vez sustituye el texto sin marcar que había
en ese hueco; después solo cambia lo que hay entre los marcadores. Guarda una
copia del SOUL anterior junto a él. Respeta HERMES_HOME.
"""
import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
START, END = "<!-- alice:persona inicio -->", "<!-- alice:persona fin -->"
STYLE_END = "<!-- alice:estilo fin -->"
PROACTIVE = "<!-- alice:proactiva inicio -->"


def with_persona(text: str, block: str) -> str:
    if START in text and END in text:
        head, rest = text.split(START, 1)
        return head + block + rest.split(END, 1)[1]
    if STYLE_END in text:
        head, rest = text.split(STYLE_END, 1)
        tail = PROACTIVE + rest.split(PROACTIVE, 1)[1] if PROACTIVE in rest else ""
        return head + STYLE_END + "\n\n" + block + "\n\n" + tail
    return block + "\n\n" + text


def saved_name(home: Path) -> str:
    """The name Alice keeps among the person's details (ask_person.py), if any."""
    for path in (home / "alice" / "details.json",):
        try:
            name = str(json.loads(path.read_text(encoding="utf-8")).get("name") or "").strip()
        except (OSError, ValueError, AttributeError):
            continue
        if name:
            return name.split()[0]
    return ""


def render(block: str, name: str) -> str:
    return block.replace("{{name}}", name)


def main(argv):
    check = "--comprobar" in argv
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    soul = home / "SOUL.md"
    name = argv[argv.index("--nombre") + 1].strip() if "--nombre" in argv and argv.index("--nombre") + 1 < len(argv) else saved_name(home)
    if not name:
        print(json.dumps({"ok": False, "error": "Falta el nombre de la persona: pásalo con --nombre o guárdalo en Alice (Ajustes › Datos personales)."}))
        return 2
    block = render((HERE / "persona.md").read_text(encoding="utf-8").strip(), name)
    text = soul.read_text(encoding="utf-8") if soul.is_file() else ""
    updated = with_persona(text, block)
    changed = updated != text
    if changed and not check:
        (home / f"SOUL.md.antes-persona-{time.strftime('%Y%m%d-%H%M%S')}").write_text(text, encoding="utf-8")
        soul.write_text(updated, encoding="utf-8")
    print(json.dumps({"ok": True, "comprobacion": check, "personalidad": "actualiza" if changed else "sin cambios"}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
