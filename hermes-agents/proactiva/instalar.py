#!/usr/bin/env python3
"""Hace que Alice tome la iniciativa en este Hermes.

    python3 instalar.py [--hora 07:30] [--comprobar]

1. Copia ``buenos_dias.py`` a ``~/.hermes/scripts/``, donde Hermes permite
   scripts de rutina.
2. Crea la rutina «Buenos días» de Alice (perfil principal) a la hora dada, en
   la zona horaria de Hermes, entregada en su chat Today (`bot-chat`). Si ya
   existe una con ese nombre, no crea otra.
3. Añade a las instrucciones de Alice cómo tomar la iniciativa (Today,
   «avísame cuando…», límites) entre marcadores; si ya estaban, las actualiza.

Nada más cambia. ``--comprobar`` dice qué haría sin tocar nada. Respeta
HERMES_HOME. Imprime un JSON con lo que hizo.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOME = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
SCRIPT = "alice_buenos_dias.py"
NAME = "Buenos días"
START = "<!-- alice:proactiva inicio -->"
END = "<!-- alice:proactiva fin -->"

PROMPT = """Escribe el «Buenos días» de Marc a partir de los hechos de abajo, que su Hermes reunió esta mañana, y de lo que sepas de él por tu memoria.

Formato, en este orden y sin títulos de sección vacíos:
1. Una línea de saludo con el día de la semana.
2. **Mientras dormías**: de una a cuatro viñetas con lo más útil que trajeron sus agentes — quién y qué, una línea cada una. Agrupa lo repetitivo («Chollometro: 3 chollos nuevos») y omite lo trivial, las confirmaciones y los acuses de recibo.
3. **Te espera**: solo si una rutina falló o algo quedó pendiente de él; di qué y el siguiente paso.
4. **Hoy**: solo si sabes algo de su día (rutinas de hoy, su calendario si tienes acceso, lo que te haya contado).
5. Una única sugerencia concreta y útil para hoy, con botones de respuesta si hay una acción clara.

Menos de 150 palabras. No inventes nada que no esté en los hechos o en tu memoria. Si no hay nada que merezca contarse, dilo en una frase amable y termina.

Hechos:"""


def run(argv, check=True):
    return subprocess.run(argv, capture_output=True, text=True, check=check, timeout=60)


def hermes() -> str:
    for candidate in (HOME / "hermes-agent" / "venv" / "bin" / "hermes", shutil.which("hermes")):
        if candidate and Path(candidate).exists():
            return str(candidate)
    raise SystemExit("No encuentro el comando hermes.")


def schedule(hour: str) -> str:
    match = re.fullmatch(r"(\d{1,2}):(\d{2})", hour)
    if not match or int(match.group(1)) > 23 or int(match.group(2)) > 59:
        raise SystemExit(f"Hora no válida: {hour}")
    return f"{int(match.group(2))} {int(match.group(1))} * * *"


def existing_jobs() -> list:
    try:
        data = json.loads((HOME / "cron" / "jobs.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    rows = data.get("jobs", data) if isinstance(data, dict) else data
    return list(rows.values()) if isinstance(rows, dict) else list(rows or [])


def with_block(text: str, block: str) -> str:
    if START in text and END in text:
        head, rest = text.split(START, 1)
        return head + block + rest.split(END, 1)[1]
    return text.rstrip() + "\n\n" + block + "\n"


def main(argv) -> int:
    check = "--comprobar" in argv
    hour = argv[argv.index("--hora") + 1] if "--hora" in argv else "07:30"
    cron = schedule(hour)
    done = {"ok": True, "comprobacion": check}

    target = HOME / "scripts" / SCRIPT
    source = (HERE / "buenos_dias.py").read_text(encoding="utf-8")
    current = target.read_text(encoding="utf-8") if target.is_file() else None
    done["script"] = "sin cambios" if current == source else ("actualiza" if current else "crea")
    if not check and current != source:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source, encoding="utf-8")

    if any(job.get("name") == NAME for job in existing_jobs()):
        done["rutina"] = "ya existe"
    else:
        done["rutina"] = f"crea ({cron}, zona de Hermes)"
        if not check:
            result = run([
                hermes(), "cron", "create", cron, PROMPT,
                "--name", NAME, "--deliver", "bot-chat", "--script", SCRIPT,
            ])
            done["hermes"] = result.stdout.strip().splitlines()[-1:] or []

    soul = HOME / "SOUL.md"
    block = (HERE / "alice-proactiva.md").read_text(encoding="utf-8").strip()
    text = soul.read_text(encoding="utf-8") if soul.is_file() else ""
    updated = with_block(text, block)
    done["instrucciones"] = "sin cambios" if updated == text else "actualiza"
    if not check and updated != text:
        soul.write_text(updated, encoding="utf-8")

    print(json.dumps(done, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
