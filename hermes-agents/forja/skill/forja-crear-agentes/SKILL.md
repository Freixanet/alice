---
name: forja-crear-agentes
description: Diseña y crea de principio a fin un agente de Hermes a medida (perfil, instrucciones, herramientas, rutinas y nombre visible en Alice) a partir de lo que la persona necesita. Úsala siempre que haya que crear un agente nuevo.
---

# Crear un agente a medida

## Resultado

Un agente nuevo, funcionando en este Hermes y visible en Alice con su nombre, diseñado para el objetivo real de la persona. Se crea con el motor compartido de Alice (`agent_create` o `scripts/crear_agente.py`); no se crea nada a mano ni con una cadena de comandos inventada.

## Antes de crear

1. Reúne lo necesario con el **intake obligatorio** de tu SOUL (clarify, una ronda, cada pregunta con default). Objetivo, entrega, idioma, frecuencia, fuentes y límites. No vuelvas a preguntar lo que ya está cerrado.
2. Diseña con [guia-agentes.md](references/guia-agentes.md): nombre, instrucciones **con ejemplos**, herramientas mínimas y rutinas.
3. Enseña el plan en lenguaje llano y confírmalo con clarify. Sin confirmación, no sigas.

## Crear

Usa la herramienta nativa **`agent_create`** cuando esté disponible. Si no, escribe la especificación en un JSON y ejecuta el script de esta skill. Ambos llaman al mismo motor.

```json
{
  "name": "resumen-mercados",
  "title": "Resumen de Mercados",
  "description": "Resume cada mañana lo importante de los mercados para un inversor particular.",
  "soul": "# Resumen de Mercados\n\n...instrucciones completas, incluida ## Ejemplos...",
  "tools": ["web"],
  "model": "muse-spark-1.3-contributor-free",
  "provider": "opencode-free",
  "routines": [
    {
      "name": "Resumen diario",
      "schedule": "0 8 * * 1-5",
      "prompt": "Prepara el resumen de hoy siguiendo tus instrucciones."
    }
  ]
}
```

- `title`: el nombre visible. Hermes lo normaliza a un identificador (`Agent Maker` → `agent-maker`). Si el identificador ya existe, elige otro nombre; no se inventa un `-2`.
- `name`: opcional si `title` basta. Minúsculas, números y guiones.
- `soul`: debe incluir `## Ejemplos` o `## Examples` con turnos de ejemplo.
- `tools`: solo las que el diseño necesita. El motor añade `clarify` y no añade browser, terminal ni code_execution por defecto.
- `model` y `provider`: juntos, si la persona eligió uno. Sin proveedor no se escribe el modelo. No hay reserva silenciosa.
- `routines`: opcional, y solo con horario confirmado. Entregan en el chat del agente (`bot-chat`).
- `reuse_profile`: si Alice ya creó el perfil para este encargo, pásalo junto con el mismo `job_id`. Un perfil de otro trabajo no se reutiliza.
- `job_id`: el mismo trabajo reanuda y no duplica perfiles ni rutinas. No es una ruta.
- `copy_memory`: obligatorio y explícito si vas a escribir `memory`. No copies USER.md ni la memoria personal entera.

Comprobar sin crear:

```bash
python scripts/crear_agente.py especificacion.json --comprobar
```

Crear (al menos 300 segundos si hay habilidades incluidas):

```bash
python scripts/crear_agente.py especificacion.json
```

`--sin-humo` omite la pregunta mínima. `--sin-atajo` no crea el wrapper de terminal.

## Después

Lee el JSON. `status: completed` y `ok: true` significan que el agente está listo. `needs_auth` quiere decir que el perfil existe pero falta autenticación del proveedor: dilo tal cual, no lo presentes como acabado. Si `status` es `partial` o `failed`, cuenta `confirmed` y `error`; no borres nada y no lo repitas a ciegas.

Cuenta a la persona en pocas frases qué agente tiene, que lo encontrará en Agents dentro de Alice (en Home), el identificador Hermes si difiere del nombre visible, y qué puede pedirle.
