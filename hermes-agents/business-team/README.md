# Business — un equipo de agentes para emprendimientos digitales

Siete agentes de Hermes que trabajan como un equipo: el Director recibe el
objetivo, reparte el trabajo con `message_agent` y convierte las entregas en
decisiones. En Alice aparecen dentro del canal **Business (Beta)**: el Director
suelto arriba y el resto en la sección *Especialistas*.

| Agente | Nombre en Alice | Para qué |
| --- | --- | --- |
| `biz-director` | Director | Objetivo, plan, reparto, integración y decisión |
| `biz-mercado` | Mercado | Clientes, demanda y competencia con fuentes |
| `biz-producto` | Producto | Propuesta de valor, MVP y experiencia |
| `biz-growth` | Growth | Posicionamiento, mensajes, canales y experimentos |
| `biz-ingresos` | Ingresos | Modelo de negocio, precios, ventas y números |
| `biz-tech` | Tecnología | Construir o comprar, stack, automatización y seguridad |
| `biz-critico` | Abogado del diablo | Riesgos, supuestos, legal y verificación |

## Qué hay aquí

- `agentes/` — el rol de cada agente.
- `compartido/equipo.md` — lo que todos comparten: quién es quién, cómo se piden
  y entregan el trabajo (PETICIÓN / ENTREGA / BLOQUEO) y el estándar de calidad.
- `instalar.py` — crea los agentes con el script de Forja (modelo estándar con
  reserva y herramienta de preguntas), añade la guía de estilo de mensajes y
  escribe `ui_meta['alice']` con el canal, la sección y el orden en que Alice los
  coloca. Nunca borra agentes.

La guía de estilo de mensajes es común a todos los agentes:
`../forja/skill/forja-crear-agentes/references/estilo-mensajes.md`. Forja la añade
a los agentes que crea, y `../aplicar_estilo.py` la pone o actualiza en los que ya
existen y en Alice, sin tocar nada más de sus instrucciones.

## Instalar

```bash
~/.hermes/hermes-agent/venv/bin/python hermes-agents/business-team/instalar.py --comprobar
~/.hermes/hermes-agent/venv/bin/python hermes-agents/business-team/instalar.py
python3 hermes-agents/aplicar_estilo.py
```

Con `--actualizar`, `instalar.py` reescribe las instrucciones, la descripción y
el sitio en Alice de los agentes del equipo que ya existen, sin tocar su modelo
ni sus herramientas.

Alice coloca a cada agente en su canal la primera vez que lo ve con esa
indicación; si después lo mueves a mano, se queda donde lo pusiste.
