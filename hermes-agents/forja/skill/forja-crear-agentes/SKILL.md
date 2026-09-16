---
name: forja-crear-agentes
description: Diseña y crea de principio a fin un agente de Hermes a medida (perfil, instrucciones, herramientas, rutinas y nombre visible en Alice) a partir de lo que la persona necesita. Úsala siempre que haya que crear un agente nuevo.
---

# Crear un agente a medida

## Resultado

Un agente nuevo, funcionando en este Hermes y visible en Alice con su nombre, diseñado para el objetivo real de la persona. Se crea con los comandos oficiales de Hermes a través de `scripts/crear_agente.py`; no se crea nada a mano.

## Antes de crear

1. Reúne lo necesario con el **intake obligatorio** de tu SOUL (clarify, una ronda, cada pregunta con default). Objetivo, entrega, idioma, frecuencia, fuentes y límites.
2. Diseña con [guia-agentes.md](references/guia-agentes.md): nombre, instrucciones **con ejemplos**, herramientas mínimas y rutinas.
3. Enseña el plan en lenguaje llano y confírmalo con clarify. Sin confirmación, no sigas.

## Crear

1. Escribe la especificación en un archivo JSON dentro de tu espacio de trabajo:

```json
{
  "name": "resumen-mercados",
  "title": "Resumen de Mercados",
  "description": "Resume cada mañana lo importante de los mercados para un inversor particular.",
  "soul": "# Resumen de Mercados\n\n...instrucciones completas, incluida ## Ejemplos...",
  "tools": ["web"],
  "routines": [
    {
      "name": "Resumen diario",
      "schedule": "0 8 * * 1-5",
      "prompt": "Prepara el resumen de hoy siguiendo tus instrucciones."
    }
  ]
}
```

- `name`: minúsculas, números y guiones; 2–40 caracteres; no puede existir ya.
- `soul`: debe incluir una sección `## Ejemplos` o `## Examples` con turnos de ejemplo. El programa la exige.
- `tools`: extras besides the ones the program already adds (`web`, `file`, `skills`, `memory`, `clarify`, `todo`). Naming a base tool is fine. Allowed extras: browser, terminal, code_execution, vision, image_gen, tts, session_search, cronjob, delegation.
- `routines`: opcional. `schedule` en formato cron o `every 2h`; entregan en el chat del agente.

2. Ejecuta el script **de esta skill** (`scripts/crear_agente.py`), con el Python de Hermes. Honra `HERMES_HOME`, `HERMES_BIN`, `ALICE_AGENT_MODEL` y `ALICE_AGENT_FALLBACK` si existen; si no, usa `~/.hermes`.

Comprueba sin crear nada:

```bash
python scripts/crear_agente.py especificacion.json --comprobar
```

3. Si la comprobación es correcta, créalo (usa al menos 300 segundos; las habilidades incluidas tardan). El programa hace después una prueba de humo (`hermes -p NOMBRE -z`); `--sin-humo` la omite:

```bash
python scripts/crear_agente.py especificacion.json
```

Si Alice ya creó el perfil y solo te pide las instrucciones, no ejecutes este script: reescribe ese `SOUL.md` con ejemplos.

## Después

Lee el JSON que imprime el programa. `ok: true` y todas las comprobaciones en `true` significan que el agente está listo, incluida la prueba de humo si no se omitió. Si algo sale `false` o hay `error`, dilo tal cual; no lo repitas a ciegas ni borres nada. Cuenta a la persona en pocas frases qué agente tiene, que lo encontrará en Agents dentro de Alice (en Home) y qué puede pedirle.
