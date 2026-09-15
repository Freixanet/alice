# Business — un equipo de agentes para emprendimientos digitales

Siete agentes de Hermes que trabajan como un equipo. Lo dirige el **Chief of
Staff**, que ya coordinaba al resto de agentes: recibe el objetivo, reparte el
trabajo con `message_agent` y convierte las entregas en decisiones. En Alice
aparecen dentro del canal **Business (Beta)**: el Chief of Staff suelto arriba y
los especialistas en la sección *Especialistas*.

| Agente | Nombre en Alice | Para qué |
| --- | --- | --- |
| `chief-of-staff` | Chief of Staff | Objetivo, plan, reparto, integración y decisión |
| `biz-mercado` | Mercado | Clientes, demanda y competencia con fuentes |
| `biz-producto` | Producto | Propuesta de valor, MVP y experiencia |
| `biz-growth` | Growth | Posicionamiento, mensajes, canales y experimentos |
| `biz-ingresos` | Ingresos | Modelo de negocio, precios, ventas y números |
| `biz-tech` | Tecnología | Construir o comprar, stack, automatización y seguridad |
| `biz-critico` | Abogado del diablo | Riesgos, supuestos, legal y verificación |

## Qué hay aquí

- `lider/chief-of-staff.md` — lo que el Chief of Staff añade a su forma de
  trabajar para un emprendimiento digital: estado por proyecto, la hipótesis más
  arriesgada primero, pasar las apuestas por el crítico y resolver lo rápido sin
  movilizar al equipo.
- `agentes/` — el rol de cada especialista.
- `compartido/equipo.md` — lo que todos comparten: quién es quién, cómo se piden
  y entregan el trabajo (PETICIÓN / ENTREGA / BLOQUEO) y el estándar de calidad.
- `instalar.py` — pone la sección del equipo en las instrucciones del Chief of
  Staff (entre marcadores, sin tocar el resto), crea los especialistas con el
  script de Forja (modelo estándar con reserva y herramienta de preguntas) y
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

Con `--actualizar`, `instalar.py` reescribe las instrucciones y la descripción de
los especialistas que ya existen, sin tocar su modelo ni sus herramientas. La
sección del Chief of Staff se actualiza en cada instalación.

Alice coloca a cada agente en su canal la primera vez que lo ve con esa
indicación, y otra vez solo si la indicación cambia; si lo mueves a mano, se
queda donde lo pusiste.
