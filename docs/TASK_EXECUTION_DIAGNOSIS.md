# Diagnóstico: ejecución de tareas (Alice vs. agentes “impecables”)

Revisado en `main` `ea068dc` (2 oct 2026). Solo diagnóstico: no hay cambios de producto en este documento.

**Pregunta del dueño:** que Alice ejecute las tareas del usuario de forma completa e independiente de lo capaz que sea el modelo que conecte (como Muse / Grok Bot / Instinct), no que “converse bien”.

**Tesis (verificada en código, no en títulos de issues):** Alice ya no es “un chat que solo hace stream”. Tiene un orquestador real —pero **casi solo para compras/recados web**. El resto de trabajo (chat Home, bots, “tareas” de Agent Maker, reservas/trámites si el modelo no llama a `errand_start`) termina cuando el modelo decide terminar. Eso **no** compensa un modelo débil.

Los “~18 issues abiertos” de GitHub **no son bugs de producto**: `open_issues_count` = 18 y todos son PRs (docs de ingeniería, auditoría, y el draft `#59` de checkout). No hay issues de fallo abiertos. El trabajo previo de “Alice bots” (`AgentTaskSession`) es **otra conversación**, no un ciclo de tarea.

---

## 1. Mapa de arquitectura: quién posee qué

```
iPhone (Alice)                         Mac / servidor (Hermes + plugin)
─────────────────                      ────────────────────────────────
Home chat  ──perfil principal──►       Gateway (chat /v1/runs, SSE)
Bot chat   ──perfil + sesión canónica─► Dashboard (perfiles, cron, vault)
Agent task ──misma herramienta,        Plugin Alice:
            otra sesión Hermes──►        pairing QR, recados, compras,
Live browser / aprobaciones /            ask_person, pay_gate, memoria,
  tarjetas seguras  ◄──────────►         goals (de vida), health, places
ErrandBoard (poll API) ◄──────►          Engine de recados + judge
BGAppRefresh (oportunista)               Cron / page_watch / notifier Mac

Web (src/) ── chat + sync + gestión ──►  mismo Hermes
             (sin recados, sin Engine)
```

| Capacidad | Quién la posee de verdad | Qué no posee |
|-----------|--------------------------|--------------|
| **Planning / descomposición** | El modelo, si llama al tool Hermes `todo`. iOS solo **pinta** `TaskPlan`. Los “objetivos” de `goals.py` son metas de días/semanas, actualizadas por el modelo. | Ningún planificador que descomponga una petición del usuario si el modelo no lo hace. |
| **Tools / bucle interno** | Hermes, **dentro de un run**: llama tools hasta que el modelo emite texto final. Alice añade tools y `pre_tool_call`. | Alice **no** reabre un run cuando el modelo se rinde. |
| **Memoria** | Hermes (`MEMORY.md` / `USER.md`). Plugin: higiene (`memory_keeper.py`), lecciones de correcciones (`lessons.py`), detalles de envío (`ask_person.py`). | No hay memoria de *tarea en curso* fuera del recado / del historial del chat. |
| **Ciclo de vida de una tarea** | **Solo recados** (`errands.py`: `working` → `needs_*` → `done`/`stuck`/`stopped`). Persistido en `~/.hermes/.alice/errands.json`. | Chat, bots y Agent Tasks no tienen estados done/stuck. Un mensaje que deja de streamear se ve “acabado”. |
| **Judge / continuación** | `Engine._judge` → `GoalManager.evaluate_after_turn` **solo en sesión `errand-*`**. | `finish_task` **no está registrado**. `auto_start` **no se llama**. El judge de Hermes en chats se pausó a propósito. |
| **Confirmación irreversible** | Pago: `pay_gate` + `checkout_request` + Face ID. Hermes: tarjetas de aprobación. Egreso/secretos: `egress_guard.py` tras leer la web. | Enviar, publicar, borrar, enviar un formulario/reserva: no hay equivalente a `checkout_request`. |
| **Fondo / offline** | Recado: hilo en el proceso del plugin + `/v1/runs` en el Mac. Cron y `page_watch` sin modelo hasta que hay novedad. | iOS no ejecuta la tarea. El Mac dormido para todo. Un recado `working` solo se relanza si alguien lista recados. |

**Contrato de identidad (hay que conservarlo):** Home = perfil principal. Un bot = su perfil y su sesión canónica. Un Agent Task = `agentTaskID` + sesión propia, sin redirigir al chat canónico. Nunca reintentar una mutación contra otro perfil.

**Pairing:** QR del plugin → canje de token de un uso → Keychain. El chat Home no es el bot seleccionado en el dashboard.

---

## 2. Huecos frente a Muse / Grok Bot / Instinct (por gravedad)

Referencia de producto (ya auditada en `docs/quality-audit-2026-09-25.md`): Muse (trabajo de fondo + permisos), Grok Bot (bots persistentes + computer use + background), Instinct (seguimiento hasta el final). Aquí no se compara UI: se compara **si el sistema termina el trabajo**.

### Critical

| # | Hueco | Por qué impide “impecable e independiente del modelo” |
|---|--------|--------------------------------------------------------|
| C1 | **No hay orquestador general.** El único bucle externo (run → judge → siguiente run → tope) es el de recados. El chat es un turno Hermes. | Un modelo débil se para en el primer obstáculo y Alice lo muestra como respuesta. No hay descomposición, verificación ni reintento de sistema. |
| C2 | **`finish_task` está muerto.** README y `task_finish.py` describen un judge sobre la sesión del chat. El plugin **reemplazó** eso por recados y **no registra** la tool. | La reclamación de producto “tareas que siguen hasta estar hechas” no aplica al chat. El código de judge/auto_start/progreso semanal mide un mecanismo que el registro de tools ya no expone. |
| C3 | **Arrancar el orquestador depende del modelo** (salvo tocada de opción de compra). Una reserva/trámite exige que el modelo llame a `errand_start`. | El modelo débil improvisa en el chat, donde el carrito está bloqueado y **no hay Engine**. |

### High

| # | Hueco |
|---|--------|
| H1 | El *brief* de todo recado está escrito como **compra** (cesta, `purchase_check_cart`, `checkout_request`, tarjeta). Una reserva o un formulario recibe el mismo contrato. |
| H2 | El Engine vive en **hilos `daemon=True`**. Tras un reinicio de gateway/dashboard, `ensure_running` solo corre al **listar** recados. El notifier Mac **lee** el JSON; no relanza el Engine. |
| H3 | Un run `interrupted`/`cancelled` **no tiene rama propia** en `Engine.run`: cae al judge con el output que haya. Riesgo de “done” o “stuck” falsos tras un corte de Hermes. |
| H4 | Independencia del modelo en compras = **pin a `gpt-6-luna` / `openai-codex`**, no scaffolding que funcione con el modelo del usuario. Si esa ruta falla, el recado no arranca. El chat sigue usando el modelo débil. |
| H5 | Confirmación de pasos irreversibles **no-pago** es prompt (`resolve_prompt`) + clasificador Hermes. No hay tarjeta “Alice va a enviar/publicar/borrar X”. |
| H6 | iOS en segundo plano es **oportunista** (`BGAppRefresh`). No continúa la tarea. El Mac tiene que estar despierto. Muse/Grok Bot asumen un computer alojado. |
| H7 | El cliente web **no tiene recados**. Misma cuenta, otra superficie: la compra/tarea web no tiene el ciclo de vida del iPhone. |
| H8 | “New Agent” / Agent Task es **identidad de conversación**, no un job con done/stuck, judge ni handoff automático al chat de origen (`docs/architecture.md`). |
| H9 | Observabilidad done vs stuck: excelente en recados; en chat, un asistente que dice “no pude” **parece terminado**. `TaskPlan` puede quedar a medias sin que el sistema lo trate como abierto. |

### Medium

| # | Hueco |
|---|--------|
| M1 | Presupuesto de prompt Hermes (4 000/sección, 8 000 total). Ya se cayeron en silencio resolver/recados/tarjetas/preguntas. Hay test, pero el andamiaje del chat **sigue siendo texto**. |
| M2 | `MAX_TURNS = 12` (goal) vs `MAX_RUNS = 14` (Engine). Un judge que no contesta se traga la excepción y **continúa una vez** (`should_continue: True`). |
| M3 | `alice_progress.py` cuenta goals `finish_task`; esas goals ya no se abren en el chat. La métrica semanal no mide recados. |
| M4 | Delegación Hermes (`subagent.*`) se muestra; el resultado asíncrono **no** se redirige a un Agent Task. |
| M5 | PR `#59` (no en `main`) documenta que en esta rama el checkout **aún depende de prosa del modelo** y de estado de browser compartido. No se asume que ese PR esté bien; sí confirma el hueco en `main`. |

---

## 3. Modos de fallo, con evidencia

### 3.1 El chat no tiene ciclo de tarea

Hermes, en **un** run, sí hace bucle de tools. Cuando el modelo emite la respuesta final, el run acaba. Alice no evalúa si la petición del usuario quedó hecha.

`evaluate_after_turn` aparece **una** vez en el repo: el Engine de recados.

```1171:1172:hermes-plugin/errands.py
    def _judge(session_id: str, reply: str) -> Dict[str, Any]:
        return _goal_manager(session_id).evaluate_after_turn(reply, user_initiated=False)
```

El registro de tools **no** incluye `finish_task`. El comentario en `register()` es residual:

```1782:1784:hermes-plugin/__init__.py
def _register_task_tools(ctx) -> None:
    """Errands (errands.py) replace finish_task: a goal on a chat's session was judged after every
    later turn of that chat, and an old purchase resumed in the middle of an unrelated question."""
```

`auto_start` (regex de comprar/carrito) solo se usa en tests. Un “prepárame la cesta…” en el chat **ya no** abre un goal.

Los goals viejos de chat se **pausan** al cargar el plugin (`_pause_chat_goals`), precisamente porque el judge del chat reanudaba compras en preguntas ajenas.

iOS aún oculta `[Continuing toward your standing goal]` en transcripciones de bots (`WebSocketBotChatSource.isGoalContinuation`). Ese camino de Hermes puede existir; **Alice ya no lo abre** para el chat.

**Fallo silencioso:** el usuario pide algo de varios pasos → el modelo se rinde o alucina “listo” → el stream termina → Live Activity acaba en “finished” → no hay `stuck`, no hay reintento, no hay prueba exigida.

### 3.2 README vs código

README (“Built, still being proven”):

> For a task with several steps, the agent opens a Hermes session goal. A separate judge model then sends it back to work…

Eso describe `task_finish.py`. El producto real para “seguir hasta el final” es `errands.Engine`, y el README también admite:

> Agents depend on the model. Long web tasks, buying in particular, succeed or fail with the model's ability. Smaller models skip steps that larger ones follow.

Las dos frases no pueden ser ciertas a la vez para el chat.

### 3.3 Recados: lo que sí orquesta, y dónde se para a medias

El Engine **sí** es el diseño que Muse-class exige, acotado a recados:

- Sesión propia `errand-<id>` (no contamina el chat).
- `open_goal` + judge + `MAX_RUNS = 14`.
- Stall 240 s, círculos en la misma página, repetición de respuesta, `BLOQUEADO:`.
- Estados visibles: `needs_approval` / `needs_input` / `needs_card` / `needs_login` / `done` / `stuck`.
- Relanzar tras reinicio **si** se lista la API.
- `pay_gate` bloquea pagar desde el chat y sin checkout aprobado (TTL 10 min).
- Aislamiento de cookies/cesta por recado.
- Compra: la persona elige opción verificada; el plugin arranca el recado al tocar (`_errand_turn`), no a discreción del modelo.

**Parada a medias — proceso:**

```1433:1433:hermes-plugin/errands.py
    thread = threading.Thread(target=body, name=f"alice-errand-{errand_id}", daemon=True)
```

```2622:2627:hermes-plugin/dashboard/plugin_api.py
async def errands_list() -> JSONResponse:
    """Every errand, newest first. An errand left working by a restart goes on from here."""
    def read():
        module, root = _errands_module(), _hermes_root()
        module.expire_checkouts(root)
        module.ensure_running(root)
```

Si el proceso muere y nadie hace `GET /errands` (iPhone cerrado, ErrandBoard sin `watch()`, notifier sin `ensure_running`), el recado queda `working` en disco **sin Engine**.

**Parada a medias — run cortado:** `FINISHED` incluye `interrupted` y `cancelled`. Tras `_wait_run`, solo hay ramas explícitas para `circling`, `stalled`, `failed`. Un `interrupted` sigue hacia el judge.

**Parada a medias — contrato de compra en tareas que no lo son:**

```842:869:hermes-plugin/errands.py
def brief(entry: Dict[str, Any]) -> str:
    ...
        "Tras añadir el formato y después de iniciar sesión, llama a `purchase_check_cart` ...
        "Cuando el pedido esté listo en el paso de pago, NO rellenes la tarjeta ni pulses pagar: "
        "llama a `checkout_request` ...
```

`START_SCHEMA` admite “booking, a form on a website” con `task`/`title`. El primer mensaje del agente **no**.

**Arranque no determinista (no-compra):** `_errand_turn` solo inyecta contexto de compra o arranca al elegir opción. Un “reserva la ITV el martes” depende de que el modelo llame a `errand_start`. Si en su lugar navega en el chat, `_guard_chat_errand` bloquea acciones de carrito, no el resto del browser.

### 3.4 Planning: display, no control

`TaskPlan` / `TaskPlanCard` aplican `todo` / `todo.updated`. `isFinished` no cierra ni reabre nada. Si el modelo no usa `todo`, no hay plan.

`goals.py`: “prepare the kids for school” — el modelo hace `goals` tick; no hay judge de pasos.

### 3.5 Andamiaje “agnóstico al modelo”

| Pieza | Ámbito | ¿Sustituye al modelo? |
|-------|--------|------------------------|
| `resolve_prompt` | Chat: “déjalo hecho”, prueba, no parar por pop-ups | No. Texto. Cabía en el presupuesto y se llegó a **tirar**. |
| Compra: discover/verify, selectores CSS, totales del DOM, `purchase_options` | Chat de compra | Parcial: valida forma; la navegación genérica sigue siendo del modelo (`docs/purchases.md`). |
| `pay_gate`, ledger de `purchase_outcome` | Recado | Sí para “no pagar dos veces / sin sí”. |
| `errand-model.json` → `gpt-6-luna` | Recados | Evita el modelo débil del chat; **exige** esa ruta. |
| Judge Hermes | Recado | Otro modelo, no un validador determinista. Si lanza, se continúa. |
| `page_watch` | Precio/stock | Sí: changedetection.io, sin modelo hasta que hay noticia. |
| Salud | Briefing | Estadística, no LLM. |
| `egress_guard` | Terminal tras leer la web | Sí: regex, no el modelo. |

Conclusión: el repo **sabe** cómo compensar (compras + watches + pago). No generalizó ese patrón.

### 3.6 Fondo, offline, iPhone

```234:236:ios/Alice/AliceApp.swift
    /// Asks iOS to wake Alice at some point. iOS decides whether and when,
    /// and never does if the app was force-quit — which is exactly why the
    /// notification copy promises "when Alice next checks" and not "instantly".
```

`handleRefresh` sincroniza dashboard, Live Activities, calendario, health, feed. **No** avanza un recado ni un chat.

`docs/request-lifecycle.md`: Alice **nunca** reintenta sola una mutación Hermes. Correcto para no duplicar pagos; implica que un fallo de red a mitad de un *chat task* no se recupera solo.

Live Activity: “working / finished / failed / stopped” según el **chat**, no según `errands.json`. Un recado puede seguir en el Mac con la Activity ya cerrada si el chat dejó de streamear.

### 3.7 Confirmación de riesgo

Bien: checkout + Face ID (`ErrandBoard.decide`); vault (login/OTP/tarjeta) fuera del chat; Hermes approvals con `ApprovalExplainer`; `ask_person` sin parar el turno; CAPTCHA pedido en el browser en vivo (prompt); `login_gate` si la persona pidió que se le pregunte.

Mal para “impecable”: enviar un correo, publicar, borrar, confirmar una reserva en la web **no** pasan por un objeto de aprobación Alice. `resolve_prompt` dice que hay que parar; un modelo débil no para, o para en texto libre sin tarjeta.

### 3.8 Bots / Agent Tasks (trabajo “Alice bots”)

`AgentTaskSession.openAgentTask`: `session.create` / `session.resume`, título UUID, `follow_profile_config`. Fallar si falta la sesión, no redirigir.

Eso evita mezclar historiales. **No** añade Engine, judge, prueba de hecho ni estados. Es Grok Bot **sin** background execution aislada: mismo Mac, mismas tools, otro hilo de chat.

`agent_engine.py` crea perfiles (CLI oficial, journal, no borrar parciales). Crea **agentes**, no ejecuta las tareas que esos agentes reciben.

### 3.9 Cliente web

Cero referencias a `errand` bajo `src/`. Chat stream + sync + management. El ciclo de recados no existe ahí.

---

## 4. Qué ya funciona y hay que conservar

No reescribir estas piezas para “parecerse a Muse”:

1. **Identidad de conexión** — Home vs bot vs Agent Task; no reroute silencioso; no impersonar un agente con el gateway del perfil principal.
2. **Recado de compra como job** — sesión propia, cesta aislada, opción tocada arranca el Engine, carrito bloqueado en el chat, checkout con total leído, `pay_gate`, ledger, Face ID, TTL, stuck con reintentar/aceptar precio.
3. **Secretos fuera del chat** — vault, `login_request` / `card_request`, nunca passwords en el transcript.
4. **`ask_person`** — preguntas en tarjeta, el trabajo independiente sigue; detalles de envío recordados.
5. **Aprobaciones Hermes en lenguaje claro** + deny por defecto en lo que el scanner marca.
6. **`egress_guard`** — taint + bloqueo de exfiltración/secretos en terminal.
7. **Browser en vivo + toma de control humana** (CAPTCHA, banco raro).
8. **Memoria con procedencia, undo, lecciones que citan al usuario** (anti-inyección).
9. **`page_watch`** y rutinas que no despiertan el modelo si el script no imprime nada.
10. **Briefings** (mañana / cita / cierre) como cron, no como el iPhone “siempre encendido”.
11. **Agent Maker** con journal y `completed` vs `partial` (el iPhone no envía el brief hasta `completed`).
12. **Mutaciones no se reintentan solas**; runs con idempotency key cuando el transporte lo permite.
13. **Eventos de stream desconocidos se conservan**; no filtrar tools de Hermes.
14. **Pairing QR** y secretos en Keychain.
15. **Activity** (`action_log.py`) — consecuencias, no el cuerpo de los mensajes.

El Engine de recados es el **núcleo a generalizar**, no un experimento a tirar.

---

## 5. Orden de arreglo recomendado (sin implementar)

1. **Ciclo de vida general, igual que un recado.** Toda petición de “haz X” (no una pregunta) entra en un job persistido: estados, sesión propia o anclada, Engine, judge con prueba, tope de runs, stall/círculo/repetición, `ensure_running` al **arrancar el plugin**, no solo al listar. El chat muestra la tarjeta; no ejecuta el trabajo. Clasificador determinista (no “el modelo se acuerda de `errand_start`”). Conservar el arranque por opción de compra.

2. **Contratos por tipo de tarea.** Compra conserva `pay_gate` / DOM / ledger. Reserva, formulario, correo, investigación: `done_when` y tools distintas. Dejar de inyectar `checkout_request` en un trámite de ITV. Sustituir el pin único `gpt-6-luna` por “ruta capaz si existe, si no el mismo bucle con validadores más duros”.

3. **Hecho = prueba, no prosa.** Schema de resultado (número de pedido, captura de confirmación, id de envío, archivo escrito). El judge o un validador **rechaza** “listo” sin prueba. `interrupted`/`cancelled` → reanudar o `stuck` visible, nunca caer al judge vacío.

4. **Puertas de confirmación para lo irreversible no-pago** (enviar, publicar, borrar, submit de reserva), mismo patrón que checkout: objeto, TTL, sí explícito, la tool no pasa sin él. Hermes approvals se quedan.

5. **Done vs stuck en el chat y en el lock screen.** Un job abierto no puede parecer un mensaje terminado. Live Activity y notifier enganchados a `errands.json` (o al job general), y `ensure_running` también desde el notifier. Web: al menos lista + aprobación, o dejar claro que el iPhone es la superficie de ejecución.

No priorizar: pulir SwiftUI, otro Agent Task de conversación, más prompt en `resolve_prompt` (el presupuesto ya se llenó una vez), ni fusionar `#59` sin re-auditar contra este `main`.

---

## Cómo se verificó esto

- Lectura de `README.md`, `docs/architecture.md`, `docs/purchases.md`, `docs/request-lifecycle.md`, `docs/proactive.md`, `docs/quality-audit-2026-09-25.md`, `docs/HANDOFF.md`, pairing, contratos Hermes.
- Código: `hermes-plugin/{errands,task_finish,__init__,ask_person,egress_guard,goals,agent_engine,alice_progress,page_watch}.py`; iOS `AgentTaskSession`, `TaskPlan`, `ChatTasks`, `ErrandBoard`, `AliceApp`, `ChatTurnRoute`, `HermesChatStream`, `AgentActivities`.
- `rg finish_task` / `register_tool` / `evaluate_after_turn` / `ensure_running` / `auto_start`.
- GitHub: 18 “issues” abiertos = 18 PRs; cero issues de fallo.

## No comprobable aquí

- Comportamiento del modelo en una conversación real, ni compras reales.
- Si Hermes core, **sin** Alice, abre goals por su cuenta (no hay checkout de Hermes en este repo; Alice no llama `evaluate_after_turn` fuera de recados).
- UI en iPhone / simulador (esta ronda no instaló nada).
- Si el plugin **desplegado** en el Mac del dueño coincide con este `main`.
- Calidad del draft `#59` (no está en `main`; no se asumió correcto).

## Riesgo que queda

El mayor: tratar el chat pulido y los Agent Tasks como si ya fueran ejecución de tareas. Un modelo más grande disimula C1–C3; uno pequeño los pone en evidencia, y el README ya lo dice. El segundo: un recado `working` sin hilo vivo parece en curso. El tercero: generalizar mal el Engine y volver a juzgar compras dentro del chat (el motivo por el que se mató `finish_task`).
