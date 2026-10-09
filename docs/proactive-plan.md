# Watchers, Review Tasks y mensajes proactivos — estado de implementación

## Resultado de la auditoría

Repositorio: `Freixanet/alice`, rama base `main`, commit
`28f48c813dbf39aa951fc89b1ff6f77cc36695ee`. Rama de trabajo:
`codex/proactive-watchers`.

El código se obtuvo de GitHub después de comprobar que la carpeta local estaba
vacía. Este documento sustituye la primera auditoría, que solo describía esa
carpeta y no había comprobado el repositorio remoto.

**Estado: fase 1 implementada y verificada con pruebas aisladas; sin desplegar.**
El usuario aprobó una ruta económica explícita por usuario, sin fallback al
principal. Sin ruta configurada no se activan watchers; errores y timeouts
conservan el evento sin ack, notify ni llamada al principal. Fases 2–3 pendientes.

## Cómo se conecta iOS con Hermes

La aplicación es SwiftUI y conecta directamente con el host Hermes del usuario.
El gateway ofrece chat y la API de runs; el dashboard ofrece administración y
sesiones canónicas mediante HTTP y WebSocket JSON-RPC. Son conexiones distintas,
que pueden tener puertos y credenciales distintos.

- `ios/Alice/Networking/HermesRPC.swift`: llamadas JSON-RPC y eventos del socket.
- `ios/Alice/Networking/DashboardClient.swift`: HTTP de administración y ticket
  de un solo uso para el socket.
- `ios/Alice/Networking/HomeChatSession.swift`: identidad del perfil principal.
- `ios/Alice/Networking/AgentTaskSession.swift`: sesiones independientes por perfil.
- `hermes-plugin/dashboard/plugin_api.py`: emparejamiento y API del plugin,
  autenticada por Hermes. El claim tiene una excepción limitada con token de
  emparejamiento; una nueva URL de webhook necesitaría su propia autenticación
  limitada, nunca una excepción global para las rutas del plugin.

Las claves de iOS se guardan en Keychain. Conversaciones y preferencias se guardan
localmente en UserDefaults con migraciones de archivos Codable. Hermes mantiene
las sesiones duraderas en su host; el plugin mantiene estado de dominio bajo
`<Hermes home>/.alice/`, por ejemplo `errands.json` y `feed.json`. La identidad
principal y las identidades de bots no son intercambiables.

Fuentes: `docs/architecture.md`, `docs/pairing.md`, `SECURITY.md` y los archivos
anteriores. Los nuevos watchers y Tasks deben guardar su autoridad y estado en
el host de cada usuario; el teléfono solo presenta y envía acciones versionadas.

## Backend y entrega de notificaciones

Sí existe un backend para el cliente web: TanStack Start/TypeScript, rutas API,
autenticación y base PostgreSQL configurable mediante `DATABASE_URL`, o PGLite
local. `src/routes/api/hermes.ts` hace proxy hacia Hermes; `src/lib/db.ts` contiene
el almacenamiento web. `SECURITY.md` documenta que el proxy recibe credenciales.
Esto no significa que el iPhone necesite ese backend. No se propone añadir allí
los eventos privados de watchers ni un servidor compartido.

**Elección de push: (a), mecanismo existente opcional, Mac notifier → Bark.**
`mac/notifier/alice_notifier.py` lee respuestas y entregas de cron en el host,
obtiene la clave Bark del Keychain y envía título, aviso genérico y enlace
`alice://open`. El cuerpo del push no es el texto de la conversación. Bark es
un servicio externo que recibe esos metadatos; no equivale a APNs propio de Alice.
Se preservaría el aviso genérico y el contenido se recuperaría del Hermes del
usuario al abrir Alice. No se propone enviar payloads o resultados del clasificador
a Bark ni introducir otro relay.

Si el usuario no configura Bark, se conserva (c), las notificaciones locales
existentes de `ios/Alice/Notifications/Notifier.swift`. La ejecución en segundo
plano es oportunista: no garantiza avisos mientras iOS suspende o cierra Alice.
No se ha detectado infraestructura APNs propia de Alice. La elección describe
código existente, no demuestra entrega real a ningún teléfono en esta auditoría.

## Lenguaje, herramientas y programación del host

El plugin usa Python y la API pública de plugins de Hermes:
`hermes-plugin/__init__.py` registra herramientas y hooks. Los agentes mantienen
sus herramientas normales; un watcher no debe heredar esas capacidades.

La programación utiliza `cron.jobs` y scripts de Hermes:

- `hermes-plugin/feed.py:ensure_schedule` crea un trabajo `no_agent` que encola
  trabajo sin iniciar un modelo.
- `hermes-plugin/page_watch.py:install_routine` programa comprobaciones de páginas.
- `hermes-plugin/task_finish.py` utiliza Goals de Hermes para tareas multietapa;
  no proporciona el nuevo modelo de Task con revisión versionada.
- `hermes-plugin/errands.py:Gateway` ofrece un cliente local de `/v1/runs` con
  proveedor/modelo explícitos. No prueba por sí solo la entrega de mensajes en
  la sesión principal ni un contrato de deduplicación durable de notificaciones.

Los scripts cron existentes no constituyen el sandbox de capacidades del
encargo. El nuevo runner deberá estar aislado, limitar recursos y delegar las
capacidades permitidas a un broker. No basta con SHA-256, timeout o quitar
variables de entorno para impedir acceso a archivos o red.

## Contrato de clasificación y ajuste aprobado

El contrato pide clasificar con el modelo configurado más barato, y que un
error del clasificador no provoque una llamada al modelo principal.

La integración auxiliar existente, `hermes-plugin/__init__.py:_review_ask`,
llama a `agent.auxiliary_client.call_llm`: en ausencia de una selección auxiliar
usa el proveedor/modelo principal. No debe reutilizarse para watchers.

Se inspeccionó de forma solo lectura el código de Hermes instalado en
`~/.hermes/hermes-agent`, commit
`6b2fe92af66a95ea6a5caa309e05c5643cdd79de`. En
`agent/auxiliary_client.py:_ladder_provider_fallback`, un error de capacidad
puede llegar a `_try_main_agent_model_fallback` incluso con proveedor explícito.
La firma pública de `call_llm` no ofrece un argumento para desactivar ese
fallback. Fijar únicamente `auxiliary.alice_watchers.provider/model` no garantiza
el aislamiento de coste pedido. Esta evidencia corresponde a ese commit
inspeccionado, no a todas las versiones de Hermes.

Además, el contrato de descubrimiento que Alice consume no incluye precios:
`src/lib/gateway-contracts.ts:HermesModelOption` contiene id, etiqueta y proveedor;
`src/lib/gateway.ts:optionFromUnknown` construye esas opciones sin tarifas.
No se puede afirmar que el modelo elegido sea el más barato de todas las cuentas,
suscripciones y endpoints personalizados a partir de ese contrato. Esto no afirma
que ningún proveedor de Hermes tenga un catálogo de precios; afirma que el
contrato actual de Alice no ofrece una comparación completa por usuario.

### Cambio mínimo propuesto

1. Hacer explícita la configuración de clasificación por usuario/host:
   proveedor, modelo y límite de coste. Si hay precios comparables verificados,
   seleccionar el más barato entre esas rutas; si faltan, pedir una ruta económica
   elegida por el usuario y describirla como elegida, sin prometer que sea la más barata.
   Nunca seleccionar silenciosamente el modelo principal.
2. Añadir un adaptador de clasificación en el plugin con ruta fija y **sin
   fallback al principal**. Utilizar un contrato público del proveedor compatible
   con la autenticación del usuario, o un contrato oficial de Hermes que garantice
   esa restricción. No modificar internals de Hermes ni su política global de fallback.
3. Ante falta de ruta, autenticación o cuota, conservar eventos y mostrar el error;
   mantener las dos tentativas del escenario requerido dentro de la misma ruta.

El usuario aprobó la ruta económica explícita por usuario y el comportamiento
classifier_error sin fallback. Se implementa HTTP directo con modelo fijo, sin
llamar al cliente auxiliar. No se han ejecutado modelos, cambiado configuraciones
reales de Hermes ni instalado/reiniciado servicios del usuario.

## Archivos previstos por fase

La fase 1 está implementada. Las fases 2–3 siguen propuestas, sin implementar.

### Fase 1 — Watchers

Añadir:

- `hermes-plugin/watchers.py`: registros, SQLite local transaccional, eventos
  pendientes, checkpoints, hashes, cuotas, deduplicación, terminales y recuperación.
- `hermes-plugin/watcher_runner.py`: proceso aislado y broker de capacidades;
  rechazar ejecución si no se puede establecer el aislamiento.
- `hermes-plugin/watcher_classify.py`: ruta económica fija, validación estricta
  de choice/yes_no/score y límite de 1–8 preguntas; sin acciones ni fallback.
- `hermes-plugin/watcher_sources.py`: correo mediante conexión detectada,
  RSS/JSON y GitHub, IDs estables y errores antes de clasificar.
- `hermes-plugin/watcher_delivery.py`: aceptación durable y batched delivery
  con identidad del perfil principal y payload/clasificación como datos.
- `hermes-plugin/tests/test_watchers.py`: los seis escenarios requeridos.
- `hermes-plugin/tests/test_watcher_runner.py`: aislamiento, hash, capacidades,
  timeout, límites de salida y dry run sin acciones reales.
- Las pruebas de clasificación y fuentes se agrupan en `test_watchers.py`;
  autenticación y contratos API en `test_watcher_api.py`.
- `ios/Alice/Networking/WatcherClient.swift`: acceso autenticado a estado y dry run.
- `ios/Alice/Features/Settings/WatchersScreen.swift`: configuración, controles y feedback.

Modificar:

- `hermes-plugin/__init__.py`: herramientas para crear, probar, activar,
  pausar, reintentar o descartar eventos; código escrito por el agente.
- `hermes-plugin/dashboard/plugin_api.py`: rutas autenticadas y webhook con
  secreto rotatable/revocable, limitado a su watcher.
- `hermes-plugin/README.md`, `docs/compatibility-matrix.md`,
  `docs/getting-connected.md` y este plan: configuración y límites reales.

La aceptación de fase exige pruebas de important, quiet, missing_body,
classifier_error, duplicate y flood. Añadir pruebas de 32 pendientes, no ack
ante error, expiración de 15 minutos, tres recargas por hora, seis notifies por
10 minutos, pausa tras una hora en límite, cuota 20 y un único aviso terminal.
El dry run debe reproducir los últimos 20 items sin modificar checkpoints,
consumir dedup o despertar al principal. Solo después de pasar, actualizar el
plan y hacer commit; no iniciar fase 2 antes.

### Fase 2 — Tasks con Needs Review

Añadir:

- `hermes-plugin/review_tasks.py`: estado del host, versiones, autonomía,
  comprobaciones contra el encargo y ciclo de vida de tarjetas de atención.
- `hermes-plugin/tests/test_review_tasks.py`: aceptación obsoleta rechazada,
  aislamiento por usuario y todos los efectos externos en draft_only.
- `ios/Alice/Models/ReviewTask.swift`: contrato distinto de ChatTasks/Goals.
- `ios/Alice/Networking/ReviewTaskClient.swift`: aceptar con versión y pedir cambios.
- `ios/Alice/Features/Tasks/TaskBoard.swift`: las cuatro columnas; blocked y failed
  deben permanecer visibles sin convertirlos en done.
- `ios/Alice/Features/Tasks/TaskReviewCard.swift`: aceptar/pedir cambio y versión nueva.
- `ios/AliceTests/ReviewTaskTests.swift`,
  `ios/AliceUITests/TaskBoardTests.swift`: fixtures y recorrido del tablero.

Modificar `hermes-plugin/__init__.py`, `hermes-plugin/dashboard/plugin_api.py`,
`ios/Alice/Features/Shell/Destinations.swift`,
`ios/Alice/Features/Shell/Sidebar.swift`,
`ios/Alice/Features/Shell/RootView.swift` y las cuatro rutas de documentación
indicadas en fase 1. La guardia de draft_only debe estar en la ejecución de
herramientas del host y rechazar operaciones desconocidas; una preferencia en
el prompt o un filtro de botones iOS no cubre todos los efectos externos.

### Fase 3 — Mensajes proactivos y rutinas

Añadir:

- `hermes-plugin/proactive_messages.py`: mensaje durable, lote y sugerencia
  única con respuesta de un toque; perfil principal, sin acciones desde payloads.
- `hermes-plugin/proactive_routines.py`: horarios/zona del usuario y resumen de
  Tasks abiertos y eventos nocturnos, mediante cron de Hermes.
- `hermes-plugin/tests/test_proactive_messages.py` y
  `hermes-plugin/tests/test_proactive_routines.py`: límites, recuperación y horarios.
- `ios/AliceTests/ProactiveMessageTests.swift`: decodificación de archivos antiguos,
  etiqueta proactiva y respuesta explícita.

Modificar `hermes-plugin/watcher_delivery.py`, `hermes-plugin/__init__.py`,
`hermes-plugin/dashboard/plugin_api.py`, `ios/Alice/Models/Chat.swift`,
`ios/Alice/Features/Chat/MessageRow.swift`,
`ios/Alice/Networking/WebSocketBotChatSource.swift`,
`ios/Alice/Features/Catalog/RoutinesScreen.swift`,
`mac/notifier/alice_notifier.py`, `mac/notifier/test_alice_notifier.py`
y la documentación
indicada en fase 1. Mantener el cuerpo de Bark genérico y recuperar contenido
solo del host Hermes.

## Evidencia y pendientes de fase 1

- Watchers: 31 pruebas aisladas, todas pasan. Incluyen los seis escenarios del
  encargo, ausencia de fallback aunque falle la ruta económica, timeout, hash,
  sandbox real macOS, scopes del webhook, quotas, presupuesto y avisos terminales.
- `npm run slash:check`: 52 comandos coinciden entre web e iOS.
- Notificador: 23 pruebas, todas pasan; ningún payload privado se incluye en Bark.
- iOS: `xcodegen generate --spec ios/project.yml` y build Debug genérico de
  dispositivo con `CODE_SIGNING_ALLOWED=NO`, resultado 0. No se instaló en iPhone.
- Regresión plugin completa: 565 pruebas, 4 fallos, 2 errores, 19 omitidas.
  Dos resultados fallidos se relacionan con `hermes_yaml` ausente; confirmado
  por un import directo en el virtualenv heredado usado por las pruebas. El archivo
  existe en el checkout de Hermes: al incluir su raíz en PYTHONPATH sí se importa. Otros tres fallos corresponden
  a Goals/SessionDB y un error a timeout del test memory_review (60 segundos).
  La reproducción completa en el commit anterior se registra abajo. No se declara
  la regresión completa como superada ni se modifica Hermes para ocultarla.
- No se hicieron llamadas a modelos, credenciales reales, Gmail, RSS, GitHub,
  push real ni instalación/reinicio de servicios. La compatibilidad real con el
  contrato `cron.bot_chat_delivery.defer` inspeccionado requiere validación
  posterior en un host sano. No se ejecutaron unit/UI iOS: este Mac prohíbe
  simuladores. La compilación no acredita comportamiento visual en un teléfono.

Comandos de verificación:

```sh
PYTHONDONTWRITEBYTECODE=1 ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests -p 'test_watcher*.py'
PYTHONDONTWRITEBYTECODE=1 ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s mac/notifier
PYTHONDONTWRITEBYTECODE=1 ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
npm run slash:check
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Alice.xcodeproj -scheme Alice -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/alice-watchers-device-build CODE_SIGNING_ALLOWED=NO -quiet build
```

## Funcionamiento y límites de esta entrega

La entrada se conserva en SQLite local. `notify` acepta primero en el inbox
transaccional del adaptador de Alice; ese recibo permite ack del evento. Después
se congela un lote de un minuto y se entrega a `Hermes.defer` con ID inmutable.
Esto evita perder avisos entre ack y entrega y permite agrupar 50 eventos. No
significa que el principal ya haya generado su mensaje cuando se confirma ack.
Si Hermes no acepta, el lote permanece y se muestra un fallo, sin inventar otra
identidad de entrega. Una aceptación ambigua no se convierte en una nueva llamada.

El runner confinado usa Seatbelt macOS, timeout, límites de salida/CPU y vigilancia
de memoria. En otros hosts se rechaza la activación: falta implementar y verificar
un sandbox equivalente. Correo requiere la skill Gmail ya conectada; RSS/JSON
y GitHub son lecturas HTTPS públicas sin redirecciones ni destinos privados.
El webhook solo encola y exige secreto rotatable más Bearer con scope exacto.

La versión nueva añade feedback (remitente/tema y menos de una categoría) y
detectores leave-now, cumpleaños y seguimiento. Se revisaron `judge.ts`,
`rules.ts` y esos detectores MIT de `mg272011/Dash-opensource`; licencia en
`THIRD_PARTY_NOTICES`. No se incorpora su backend ni código de Comma.

Archivos auxiliares: `watcher_common.py`, `watcher_builtins.py`,
`watcher_service.py`, `watcher_tools.py`. AppStore solo añade el acceso al cliente.
Los cumpleaños y seguimientos usan datos explícitos; leave-now requiere calendario
fresco, dirección física y minutos de viaje proporcionados, sin adivinar ETA.

Fases 2–3 pendientes: tablero Tasks/Needs Review, aprobación versionada, rutinas
proactivas y presentación enriquecida en chat. Esta fase entrega avisos agrupados
al chat existente, sin afirmar que esas fases estén implementadas.


## Comparación anterior a fase 2 (9 de octubre de 2026)

Por petición del usuario se obtuvo un checkout detached de `684c4da`, padre de
`9dc0dcc`, en `/private/tmp/alice-before-watchers-684c4da`. Se ejecutó
la suite plugin completa con el mismo virtualenv y sin PYTHONPATH adicional:

```sh
cd /private/tmp/alice-before-watchers-684c4da
PYTHONDONTWRITEBYTECODE=1 /Users/mfreixanet/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests -v
```

Resultado: **540 pruebas, 95.263 segundos, 4 failures, 2 errors, 19 skipped**.
Log conservado en `/private/tmp/alice-baseline-684c4da-tests.log`.
Estos seis nombres y causas coinciden con la ejecución completa reportada en
fase 1 (565 pruebas, 4 failures, 2 errors, 19 skipped):

| Resultado | Test | Causa en ambas ejecuciones |
| --- | --- | --- |
| FAIL | `test_agent_engine.Safety.test_delayed_hermes_session_is_refused_before_any_move` | `hermes_yaml` no importable |
| FAIL | `test_ask_person.GoalWaitTests.test_an_open_question_parks_the_goal_and_its_answer_releases_it` | Goal no queda esperando; SessionDB no disponible |
| FAIL | `test_task_finish.AutoGoalTests.test_an_errand_opens_its_goal` | Goal no queda activo; SessionDB no disponible |
| FAIL | `test_task_finish.AutoGoalTests.test_the_same_reply_twice_pauses_the_goal` | Guard de repetición no pausa Goal |
| ERROR | `test_task_finish.FinishTaskTests.test_the_tool_uses_the_chat_turn_session` | `hermes_yaml` no importable |
| ERROR | `test_memory_review.HermesReviewTests.test_reads_each_message_once_and_writes_through_hermes` | Subprocess timeout de 60 segundos |

**Ninguno de los seis es nuevo en Watchers.** La ejecución actual no se repitió
completa: ya existía esa evidencia; se verificaron los 31 tests específicos tras
corregir el caso real de Gmail vacío (`No messages found.` → sin eventos).

Se comprobó además, sin modelos ni correo, que el intérprete administrado que
Hermes selecciona mediante `pm.environments.project_python` importa cron/entrega
y ejecuta `Runner().run("pass", ...)` bajo confinamiento. No es el antiguo venv
que usó la suite; la guía descubre el intérprete correcto. Esto es un smoke check
de imports/runner, no una prueba de entrega real.

Opción push implementada: **mecanismo existente Mac → Bark**. No nuevo relay.
Bark recibe avisos genéricos; el contenido se obtiene de Hermes al abrir Alice.
Las notificaciones locales existentes son oportunistas, sin garantía con Alice
suspendida o cerrada a la fuerza. El usuario no tiene que configurar un relay
nuevo para esta opción.

[Guía exacta de instalación y primer watcher Gmail](watchers-first-email.md).
La consulta de solo lectura del iPhone falló por conexión CoreDevice; no se conoce
su build actual y no se instaló nada. La guía pide comprobar e incrementar el
número instalado. Tampoco se envió correo ni se llamó a un modelo real.
El parche estándar no se aplica al `__init__.py` instalado porque incluye una
integración previa de compras adicional. La guía compone solo la inserción de
Watchers sobre ese archivo y conserva esos hooks. Se comprobó la sintaxis del
resultado y `git apply --check` sobre el plugin real: resultado 0, sin modificarlo.
No se usó el instalador general, que sobrescribiría archivos vivos.
**Fase 2 no iniciada.**
