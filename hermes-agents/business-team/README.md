# Business — un equipo de agentes para emprendimientos digitales

Once agentes de Hermes que trabajan como un equipo. Lo dirige el **Chief of
Staff**, que ya coordinaba al resto de agentes: recibe el objetivo, reparte el
trabajo con `message_agent` y convierte las entregas en decisiones. En Alice
aparecen dentro del canal **Business (Beta)**: el Chief of Staff suelto arriba y
los especialistas en departamentos, en el orden en que avanza un proyecto
(entender, definir, construir, vender).

| Agente | Nombre en Alice | Departamento | Para qué |
| --- | --- | --- | --- |
| `chief-of-staff` | Chief of Staff | — (arriba) | Objetivo, plan, reparto, integración y decisión |
| `evals` | Evals | — (arriba) | Si cada agente trabaja bien: benchmarks, regresiones y torneo de modelos (con Luna) |
| `biz-mercado` | Mercado | Intelligence Dept. | Qué quiere el cliente, demanda y competencia con fuentes |
| `biz-critico` | Abogado del diablo | Intelligence Dept. | Riesgos, supuestos, legal y verificación |
| `biz-scout` | Scout | Intelligence Dept. | Vigilancia continua, fichas de competidores y oportunidades (ronda diaria a las 8:00, informe los lunes) |
| `biz-investigacion` | Investigación | Intelligence Dept. | Preguntas abiertas investigadas a fondo, con números y ranking |
| `biz-producto` | Producto | Product Dept. | Mayor cuello de botella de valor, tablero de oportunidades, MVP y experiencia |
| `biz-tech` | Arquitecto | Engineering Dept. | Diseño antes del código, builders temporales en paralelo e integración; stack, seguridad e instrumentación |
| `biz-calidad` | Calidad | Engineering Dept. | Revisión de código independiente y control de release, con otro modelo (Luna) |
| `biz-growth` | Growth | Revenue Dept. | Posicionamiento, mensajes, canales y experimentos |
| `biz-ingresos` | Ingresos | Revenue Dept. | Modelo de negocio, precios, ventas y números |

## Qué hay aquí

- `lider/chief-of-staff.md` — lo que el Chief of Staff añade a su forma de
  trabajar para un emprendimiento digital: estado por proyecto, la hipótesis más
  arriesgada primero, pasar las apuestas por el crítico y resolver lo rápido sin
  movilizar al equipo.
- `agentes/` — el rol de cada especialista.
- `compartido/plantilla-*.md` — la estructura de las fichas de competidores, del
  documento de cliente, del tablero de oportunidades, del plan de medición, del
  diseño técnico y del control de release.
- `compartido/equipo.md` — lo que todos comparten: quién es quién, cómo se piden
  y entregan el trabajo (PETICIÓN / ENTREGA / BLOQUEO) y el estándar de calidad.
- `instalar.py` — pone la sección del equipo en las instrucciones del Chief of
  Staff (entre marcadores, sin tocar el resto), crea los especialistas con el
  script de Forja (modelo estándar con reserva y herramienta de preguntas) y
  escribe `ui_meta['alice']` con el canal, el departamento, el orden y la lista de
  departamentos del canal. Alice ordena las secciones así y quita las vacías que
  no estén en la lista; nunca una con agentes. Nunca borra agentes.

## Evals

`evals` evalúa a todos los agentes de este Hermes con benchmarks propios. Su
herramienta, `../evals/evals.py`, se instala en
`~/hermes-workspaces/evals/herramienta/` y hace el trabajo determinista: huellas de
cambios (instrucciones, modelo, herramientas, skills y memoria), lista de modelos
desde la caché de Hermes, ejecución de suites con coste y latencia (`hermes -z
--usage-file`), juez con un modelo distinto al evaluado, marcador por agente y
cambio o reversión de modelo con copia de seguridad. Toda evaluación corre en el
perfil `evals-sandbox` (oculto en Alice), sincronizado antes con el agente y solo
con herramientas que no escriben, no ejecutan comandos ni programan rutinas.
Rutina diaria de cambios a las 7:00 y torneo de modelos los domingos a las 5:00;
en esta fase ningún cambio de modelo se aplica sin tu sí. Pruebas:
`~/.hermes/hermes-agent/venv/bin/python hermes-agents/evals/prueba_evals.py`
(contra un Hermes falso).

## Builders temporales

El Arquitecto no escribe todo el código: tras diseñar, lanza builders temporales
en paralelo (backend, frontend, tests desde los criterios de aceptación y
migraciones reversibles), cada uno en su propia copia del repositorio
(`delegation.worktree_isolation` en su perfil), con un encargo cerrado y sus
archivos. Los builders no preguntan ni usan memoria y desaparecen al terminar;
Hermes no junta su trabajo solo: el Arquitecto revisa cada rama, la integra,
ejecuta los tests, comprueba los criterios, pide la revisión de Calidad (otro
agente, con otro modelo, que nunca escribe el código que revisa) y limpia las
copias.

## Carpeta compartida

`~/hermes-workspaces/business/` guarda lo que el equipo sabe, para que nadie repita
trabajo: `proyectos/<proyecto>/estado.md` (del Chief of Staff),
`proyectos/<proyecto>/cliente.md` (qué quiere el cliente, de Mercado),
`proyectos/<proyecto>/oportunidades.md` (problema → impacto → confianza → coste →
experimento mínimo → resultado, de Producto),
`proyectos/<proyecto>/medicion.md` (embudo y eventos de Producto, instrumentados y
verificados por el Arquitecto; nada se lanza sin él),
`proyectos/<proyecto>/diseno/` (requirement → arquitectura → interfaces → archivos
afectados → plan → criterios de aceptación, del Arquitecto),
`proyectos/<proyecto>/calidad/` (revisiones de código y controles de release, de
Calidad; nada llega a producción sin su *Adelante* y tu confirmación), `competidores/`
(fichas vivas del Scout; la decisión de «Nuestra respuesta» es del Chief of
Staff), `vigilancia.md` (del Scout) e `investigaciones/` (de Investigación). En
las instrucciones aparece como `{{BUSINESS_DIR}}` y el instalador pone la ruta
real. Cada archivo tiene un solo dueño; el resto lo lee.

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
