---
name: forja-crear-agentes
description: Diseña y crea de principio a fin un agente de Hermes a medida (perfil, instrucciones, herramientas, rutinas y nombre visible en Alice) a partir de lo que la persona necesita. Úsala siempre que haya que crear un agente nuevo.
---

# Crear un agente a medida

## Resultado

Un agente nuevo, funcionando en este Hermes y visible en Alice con su nombre, diseñado para el objetivo real de la persona. Se crea con los comandos oficiales de Hermes a través de `scripts/crear_agente.py`; no se crea nada a mano.

## Antes de crear

1. Reúne lo necesario: objetivo, qué entrega y en qué formato, fuentes o datos que usa, frecuencia (si es periódico), tono e idioma, y qué no debe hacer.
2. Pregunta con clarify solo lo que cambie el diseño y no puedas deducir. Ofrece opciones concretas con una recomendada.
3. Diseña con [guia-agentes.md](references/guia-agentes.md): nombre, instrucciones, herramientas mínimas y rutinas.
4. Enseña el plan en lenguaje llano y confírmalo con clarify. Sin confirmación, no sigas.

## Crear

1. Escribe la especificación en un archivo JSON dentro de tu espacio de trabajo:

```json
{
  "name": "resumen-mercados",
  "title": "Resumen de Mercados",
  "description": "Resume cada mañana lo importante de los mercados para un inversor particular.",
  "soul": "# Resumen de Mercados\n\n...instrucciones completas...",
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
- `tools`: solo las que el objetivo necesita, además de las básicas que añade el programa (web, file, skills, memory, clarify, todo). Permitidas: browser, terminal, code_execution, vision, image_gen, tts, session_search, cronjob, delegation.
- `routines`: opcional. `schedule` en formato cron o `every 2h`; entregan en el chat del agente.

2. Comprueba sin crear nada:

```bash
~/.hermes/hermes-agent/venv/bin/python ~/.hermes/profiles/forja/skills/productivity/forja-crear-agentes/scripts/crear_agente.py especificacion.json --comprobar
```

3. Si la comprobación es correcta, créalo:

```bash
~/.hermes/hermes-agent/venv/bin/python ~/.hermes/profiles/forja/skills/productivity/forja-crear-agentes/scripts/crear_agente.py especificacion.json
```

Usa un límite de tiempo de al menos 300 segundos: añadir las habilidades incluidas tarda.

## Después

Lee el JSON que imprime el programa. `ok: true` y todas las comprobaciones en `true` significan que el agente está listo. Si algo sale `false` o hay `error`, dilo tal cual; no lo repitas a ciegas ni borres nada. Cuenta a la persona en pocas frases qué agente tiene, que lo encontrará en Agents dentro de Alice (en Home) y qué puede pedirle.
