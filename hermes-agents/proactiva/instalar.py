#!/usr/bin/env python3
"""Hace que Alice tome la iniciativa en este Hermes.

    python3 instalar.py [--hora 07:30] [--comprobar]

1. Copia los scripts de las rutinas a ``~/.hermes/scripts/``, donde Hermes
   permite scripts de rutina.
2. Crea las rutinas de Alice (perfil principal), entregadas en su chat Today
   (`bot-chat`), en la zona horaria de Hermes:
   - «Buenos días», a la hora dada (``--hora``, 07:30 por defecto);
   - «Antes de cada cita», cada 15 minutos en modo monitor: el modelo solo se
     despierta cuando una cita entra en la hora siguiente;
   - «Cierre del día», a las 21:30.
   Si una ya existe con ese nombre, no crea otra; solo actualiza su prompt.
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
START = "<!-- alice:proactiva inicio -->"
END = "<!-- alice:proactiva fin -->"

PROMPT = """Escribe el «Buenos días» de Marcos a partir de los hechos de abajo, que su Hermes reunió esta mañana, y de lo que sepas de él por tu memoria. No es un resumen de noticias: es su tablero de mando, lo que necesita su atención antes de empezar el día.

Formato, en este orden, y omite cualquier sección sin nada que decir:
1. Una línea de saludo con el día de la semana.
2. **Hoy**: sus citas en orden, y bajo cada una lo que hay que preparar, llevar o saber (por tu memoria, el lugar, la hora de salida); sus recordatorios de hoy y los vencidos.
3. **Pendiente**: lo que espera algo de él — recordatorios vencidos o urgentes, el siguiente paso de un objetivo que no avanza, una rutina que falló — cada uno con el siguiente paso concreto.
4. **Sistema**: si todo está en orden, una sola línea («Todo en orden: 118 GB libres, Hermes en marcha»). Si algo está en MAYÚSCULAS en los hechos (poco espacio, presión de memoria, batería baja, un servicio parado, una web caída) o hay muchos errores de un mismo origen, dilo primero en esta sección, con qué significa y qué hacer. No listes errores sueltos que no le afecten.
5. **Mientras dormías**: de una a tres viñetas con lo más útil que trajeron sus agentes; agrupa lo repetitivo y omite lo trivial.
6. Una única sugerencia concreta para hoy, con botones de respuesta si hay una acción clara (por ejemplo, «Sí, libera espacio» o «Reintenta la rutina»).

Lo más urgente va primero dentro de cada sección. Cuando algo encaje con algo que sabes que le importa, dilo en pocas palabras.

Entrégalo en tres partes separadas por una línea con solo `---`: el saludo del punto 1, una sola frase corta que avise de que ahí va su resumen de la mañana, sin análisis; los puntos 2 a 5; y el punto 6 como cierre, breve y personal. Alice muestra la primera y la última como tus mensajes y lo del medio en su tarjeta.

Menos de 200 palabras. No inventes nada que no esté en los hechos o en tu memoria. Si no hay nada que merezca contarse, dilo en una frase amable y termina (sin `---`).

Hechos:"""


PROMPT_CITA = """Una cita de Marcos empieza en torno a una hora: está en las líneas nuevas del cambio que ves arriba. Si no hay ninguna cita nueva (la lista quedó vacía o solo desapareció una), responde solo [SILENT].

Si la hay, escríbele un aviso breve, de menos de 60 palabras:
- qué y a qué hora, en una línea;
- lo útil que sepas por tu memoria sobre esa cita, la persona o el lugar, si sabes algo;
- algo práctico solo si aplica: salir con tiempo si hay un lugar, qué llevar, qué preparar.

Entrégalo así: una frase tuya para él, cercana (qué viene y lo principal); una línea con solo `---`; debajo, el aviso. Sin relleno. No inventes nada que no esté en la cita o en tu memoria."""

PROMPT_CIERRE = """Escribe el resumen de la noche de Marcos a partir de los hechos de abajo. Todo lo que necesitas está aquí: no cargues skills ni uses herramientas (su protocolo INICIO/CIERRE es otra cosa y no aplica). Sale todas las noches: corto, cálido y útil, nunca más de 90 palabras. En este orden:

1. **Quedó abierto** (solo si hay algo): como mucho tres cosas que él dijo que haría, prometió a alguien o dejó sin cerrar hoy, una línea cada una, cada una con su botón `[Recuérdamelo mañana](alice://reply?text=Recu%C3%A9rdame%20ma%C3%B1ana%20a%20las%209%3A%20…)` (texto codificado como en una URL). Nada resuelto, nada que solo fuera una pregunta o una prueba.
2. **Mañana**: una línea con su agenda —el calendario y lo que él te dijo hoy que tiene mañana—, o «mañana lo tienes libre» si no hay nada. Si algo que te dijo no está en el calendario, debajo, sola: `[Añadir a tu calendario](alice://calendar/add?title=…&date=AAAA-MM-DD)` (con `time` si lo sabes).
3. Una última línea tuya, con su tono de siempre: una idea concreta para mañana o, si el día fue tranquilo, algo breve para desconectar. Sin frases hechas ni «¿algo más?».

Entrégalo en tres partes separadas por una línea con solo `---`: una frase corta y cálida que avise de que ahí va su cierre del día, sin análisis; los puntos 1 y 2; y el punto 3 como cierre.

No inventes nada que no esté en los hechos o en tu memoria. No respondas [SILENT].

Hechos:"""

# name, schedule, prompt, script file here, installed name, monitor mode
JOBS = [
    ("Buenos días", None, PROMPT, "buenos_dias.py", "alice_buenos_dias.py", False),
    ("Antes de cada cita", "*/15 * * * *", PROMPT_CITA, "antes_de_cita.py", "alice_antes_de_cita.py", True),
    ("Cierre del día", "30 21 * * *", PROMPT_CIERRE, "cierre_dia.py", "alice_cierre_dia.py", False),
]

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

    scripts = {}
    for name, when, prompt, source_name, installed, monitor in JOBS:
        target = HOME / "scripts" / installed
        source = (HERE / source_name).read_text(encoding="utf-8")
        current = target.read_text(encoding="utf-8") if target.is_file() else None
        scripts[installed] = "sin cambios" if current == source else ("actualiza" if current else "crea")
        if not check and current != source:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source, encoding="utf-8")
    done["scripts"] = scripts

    existing = existing_jobs()
    routines = {}
    for name, when, prompt, source_name, installed, monitor in JOBS:
        found = next((job for job in existing if job.get("name") == name), None)
        if found:
            # A routine is the person's once made: only its prompt follows this
            # file, never the time or where it delivers, which they may change.
            if (found.get("prompt") or "").strip() == prompt.strip():
                routines[name] = "ya existe"
            else:
                routines[name] = "actualiza el prompt"
                if not check:
                    run([hermes(), "cron", "edit", str(found.get("id")), "--prompt", prompt])
            continue
        schedule_for = when or cron
        routines[name] = f"crea ({schedule_for}, zona de Hermes)"
        if not check:
            argv = [hermes(), "cron", "create", schedule_for, prompt,
                    "--name", name, "--deliver", "bot-chat"]
            argv += ["--monitor-script", installed] if monitor else ["--script", installed]
            run(argv)
    done["rutinas"] = routines

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
