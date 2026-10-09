# Watchers, Review Tasks y mensajes proactivos — paso 0

## Resultado de la auditoría

Repositorio: `Freixanet/alice`, rama base `main`, commit
`28f48c813dbf39aa951fc89b1ff6f77cc36695ee`. Rama de trabajo:
`codex/proactive-watchers`.

El código se obtuvo de GitHub después de comprobar que la carpeta local estaba
vacía. Este documento sustituye la primera auditoría, que solo describía esa
carpeta y no había comprobado el repositorio remoto.

**Estado: auditoría realizada; implementación detenida por una incompatibilidad
con el contrato de clasificación.** No se han iniciado las fases 1–3.

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

## Incompatibilidad que obliga a detenerse

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

La primera propuesta ajusta la exigencia de «el más barato» cuando no hay datos
comparables. Conforme al paso 0 del encargo, se informa y se detiene aquí antes de
implementar una interpretación diferente. No se han ejecutado modelos, cambiado
configuraciones de Hermes ni instalado/reiniciado servicios del usuario.

## Archivos previstos por fase

Estas son las rutas concretas propuestas, pendientes de resolver la incompatibilidad.
Los archivos nuevos enumerados aquí todavía no existen.

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
- `hermes-plugin/tests/test_watcher_classify.py`: respuestas malformadas,
  incertidumbre, opciones quiet/none y ausencia de fallback.
- `hermes-plugin/tests/test_watcher_sources.py`: fuentes falsas, paginación,
  redirecciones y límites de origen para HTTP.
- `ios/Alice/Networking/WatcherClient.swift`: acceso autenticado a estado y dry run.
- `ios/AliceTests/WatcherClientTests.swift`: fixtures de errores y contratos.

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

## Evidencia y pendientes

**Comprobado:** remoto y rama de Alice descargados; identidad y commit base;
lectura de `AGENTS.md`, arquitectura, seguridad, verificación, compatibilidad,
transportes iOS, plugin Python, cron, notificador y selección auxiliar del
Hermes instalado. No se consultó ni copió AFK-surf/Comma.

**No comprobable en esta auditoría:** entrega real de push, comportamiento de
modelos, credenciales/cuotas, confinamiento de un runner aún no construido y
aceptación durable de notify. No se ejecutaron pruebas de fases inexistentes.
Este Mac no dispone de simulador iOS y `AGENTS.md` prohíbe instalarlo o ejecutar
`scripts/verify-ios.sh` aquí. Para cambios iOS, realizar build de dispositivo y
reportar unit/UI como pendientes hasta ejecutarlos en otro entorno.

**Riesgo restante:** reutilizar clasificación auxiliar puede gastar el modelo
principal, y elegir «el más barato» sin precios verificables sería una promesa
incorrecta. Ninguna fase está terminada; se necesita resolver el contrato de
clasificación antes de implementarlas y validar cada una con sus pruebas y commit.
