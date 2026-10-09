# Watchers, Review Tasks y mensajes proactivos — estado de implementación

## Estado vigente — 9 octubre 2026

Rama `codex/proactive-watchers`. Plugin instalado: `958cc0e`; app iPhone:
build 97, `99f3b7f`. El cambio posterior del plugin no requiere otra app.
Las compras están desactivadas y sus herramientas no se registran.

- **Fase 1:** Watchers, fuentes, sandbox, ruta clasificadora explícita,
  feedback, eliminación, recuperación y validación antes de activar están
  implementados. El watcher Barkibu conserva el ID
  `5f9b8bde37f746fbb3d24dab0eeb6d70`, con consulta de Barkibu y baseline nuevo.
  Un correo posterior fue procesado y su aviso visible en el iPhone confirmado
  por el usuario. El acceso del teléfono al host requiere Tailscale conectado.
  Lecturas reales de RSS (BBC, 32 elementos) y GitHub (python/cpython, 100
  elementos) verificadas con el adaptador del plugin, sin clasificar ni crear
  watchers. Falta el recorrido de notificación completo de esas fuentes;
  webhooks y detectores integrados sólo tienen pruebas aisladas.
- **Fase 2:** tablero Tasks, estados del host, revisiones versionadas,
  comprobaciones, continuidad en la sesión original y autonomía están
  implementados. Petición de cambios, aceptación y finalización probadas en el
  iPhone; el fallo descubierto y la recuperación manual están documentados abajo.
  Una segunda Task verificó el recorrido corregido sin intervención manual.
- **Fase 3, alcance autorizado:** un aviso marcado por lote con qué ocurrió,
  por qué importa y una respuesta de un toque; una sola rutina matinal, por
  defecto 08:00 Europe/Madrid, silenciosa si no hay novedades; agrupación y
  contador diario/semanal de llamadas de avisos y briefings. El clasificador
  económico y las respuestas normales del chat están fuera de ese contador.
  El redactor recibe sólo el lote actual, sin historial ni memorias anteriores;
  los avisos ya entregados conservan su texto. Briefing real entregado por el
  programador y contador verificado en el host; pendiente confirmación visual
  del iPhone. Agrupación de eventos en la ventana y respuesta de un toque
  tienen pruebas aisladas, pendiente comprobación real de esos recorridos.
- **Push:** mecanismo existente Mac → Bark, con aviso genérico y apertura de
  Alice; el contenido se recupera del Hermes de cada usuario.
- **Fuera del alcance acotado implementado:** responder desde la propia
  notificación con peticiones firmadas/reintento, y tarjetas con varias opciones
  que creen Tasks conservando el contexto. No añadir más tipos de rutinas.

Comprobación real de Tasks en curso: misma Task
`7c2c4723a4e742498e900f046161cdf9` («Validación de Tasks — nota de prueba»).
El usuario encontró la tarjeta en la columna horizontal Para revisar y pidió
una frase de máximo ocho palabras. La continuación real produjo «Gracias de
corazón; lo valoro mucho.» (seis palabras), pero el código permitió finalizar
sin nueva aceptación y borró el texto al omitir `blocks_json`.
`958cc0e` corrige ambos fallos: la revisión pendiente persiste hasta aceptar y
omitir bloques conserva el resultado. Tres regresiones fallaban antes y las
24 pruebas Tasks/API/hook pasan con la corrección. Plugin instalado con backup;
no requiere reinstalar la app. Se recuperó manualmente el resultado de la
respuesta original del modelo (mensaje 23697), con copia del registro anterior,
sin otra llamada al modelo ni crear una Task: `needs_review`, versión 7.
El usuario aceptó desde el iPhone: Hermes terminó la misma Task en versión 9,
con `review_required=false`, el bloque de seis palabras intacto y cuatro
comprobaciones. Aceptación y finalización reales verificadas por API; no se envió
la nota ni se utilizó un servicio externo. La nueva revisión anterior fue una
recuperación manual del fallo, no una segunda revisión autónoma del modelo.

Segunda comprobación real, sin recuperación manual:
`5ee7a30e1f234b91980c5ddd0bc70785` («Validación de Tasks — segunda revisión»).
El usuario pidió máximo cuatro palabras; Alice volvió a `needs_review`, versión 5,
con «Gracias, lo aprecio.» (tres palabras), `review_required=true` y tarjeta visible
confirmada. Tras aceptación desde iPhone terminó en versión 7 con el mismo texto
intacto y `review_required=false`. La comprobación escrita por el modelo decía
cuatro palabras; no tomar sus comprobaciones declaradas como verificación automática.

Verificación más reciente: suite completa de 713 pruebas en 20,1 segundos;
708 pasan, una omitida y cuatro fallos del runner porque el sandbox de Codex
rechaza `sandbox-exec` (`sandbox_apply: Operation not permitted`). Las cinco
pruebas de ese módulo pasan al ejecutarlas fuera de esa restricción, sin cambios
a las aserciones. No se repitió toda la suite después. La prueba original de
memoria que antes agotaba 60 segundos pasa aisladamente en 1,7 segundos, intacta;
el diagnóstico de arranque detectó que Hermes intenta completar dependencias de
una actualización pendiente. No se modificaron Hermes ni sus dependencias.
Las 18 pruebas proactivas/agrupación pasan, incluida una ráfaga de 50 eventos en
un lote, briefing vacío sin llamadas y aislamiento de redacción. El ledger real
registra una llamada principal para el aviso Barkibu `0972bfd750f14fa4848376ebde4b12a7`.
No se han ejecutado pruebas de UI sobre datos reales ni simulador en este Mac.

Briefing real adelantado con autorización del usuario a 01:44 Europe/Madrid
(del 10 octubre en esa zona; 9 octubre en America/New_York). El cron existente
lo generó automáticamente: entrega `131ce94248ce4dfea97a7f43b97f4923`, siete
actualizaciones captadas desde el inicio (primer briefing) y ninguna Task abierta.
Recibo `settled`; un único mensaje principal (23730) con `happened`, `matters`
y `reply`, sin herramientas, y una llamada `gpt-6-luna` en el ledger. El API
muestra para el día configurado en Madrid: proactive 1, briefing 1, total 2.
Se restauraron inmediatamente 08:00 Europe/Madrid y enabled=true; no se borró
el cursor ni `last_date`. La prueba cuenta como el briefing del día de Madrid,
por lo que no vuelve a enviar otro a las 08:00 de ese mismo día. Pendiente
confirmar la tarjeta, los valores y el horario en la pantalla del iPhone.

Guías vigentes: [Watchers y Gmail](watchers-first-email.md),
[Tasks y revisiones](tasks-review.md), [fase 3 y comprobaciones](watchers-phase3.md).
Las secciones siguientes conservan la auditoría y evidencias históricas;
sus builds y estados intermedios no describen la instalación actual.

## Resultado de la auditoría

Repositorio: `Freixanet/alice`, rama base `main`, commit
`28f48c813dbf39aa951fc89b1ff6f77cc36695ee`. Rama de trabajo:
`codex/proactive-watchers`.

El código se obtuvo de GitHub después de comprobar que la carpeta local estaba
vacía. Este documento sustituye la primera auditoría, que solo describía esa
carpeta y no había comprobado el repositorio remoto.

**Estado histórico al cierre inicial de fase 1:** fase 1 validada desde `0e0490e`, build 92;
correo real, notificación y apertura de Alice confirmados por el usuario. La ruta
clasificadora sigue siendo explícita y nunca utiliza el modelo principal como fallback.

Fase 2: app instalada y abierta en el iPhone, build 93 (`2b8dc28`); plugin
instalado desde `codex/proactive-watchers`, con recibo `INSTALLED_FROM` y backup.
Tasks con autoridad SQLite en el host, versiones estrictas,
una tarjeta vigente por tarea, resultados nativos de solo datos y decisiones desde
iOS. `review_tasks` prepara y actualiza; solo la API autenticada permite aceptar o
cambiar autonomía. El hook previo a herramientas consume una autorización exacta
una sola vez, vinculada a perfil, conversación y versión. `draft_only` bloquea
operaciones externas también fuera de Tasks; en `act` las conversaciones anteriores
siguen sujetas a sus controles existentes. Los perfiles y Goals/recados se conservan.

«Aceptar», «Pedir cambios» y responder a un bloqueo guardan primero la decisión.
iOS reanuda la conversación de origen, reclama una continuación única en el host y
la envía por el RPC existente. Una respuesta ambigua no se reenvía automáticamente.
Las identidades devueltas por Hermes se vinculan sin cambiar el perfil original.
Los argumentos son exactos; para recursos externos mutables el agente debe volver
a comprobar el contenido y pedir otra revisión si cambió. No existe una transacción
atómica entre Hermes y proveedores externos.

Referencia Dash MIT revisada: commit `7ef7292`, `AGENT_HARNESS.md`,
`lib/harness/result-blocks.ts` y `app/result-blocks.tsx`. Se adaptaron sus patrones
de resultados como datos y comprobación de autorizaciones en el host; licencia y
copyright conservados en `THIRD_PARTY_NOTICES`. No se usó código Comma/AFK.
En ese punto aún no se había iniciado la fase 3; el estado vigente está arriba. Uso: [Tasks y revisiones](tasks-review.md).

## Corrección de la comparación de fallos

La comparación con `0e0490e` ocultaba la diferencia frente a `684c4da`: los doce
casos adicionales nacieron en `283bbaa` y entraron por el merge de recuperación
`4befbc1`, durante fase 1. Se reprodujo el antes/después de ambos commits.
Corregidos el camino de lectura sin protección al perder el contexto y las
pruebas desactualizadas, la suite vuelve a los seis originales: 668 pruebas,
4 fallos + 2 errores y 19 omitidas. El módulo de recados pasa 84 pruebas.
Detalle por caso y evidencias: [auditoría de regresiones](watchers-regression-audit.md).
Los resultados de 18 casos que siguen abajo son históricos, anteriores al arreglo.

## Verificación de fase 2

- Suite completa del commit instalado `0e0490e`: 643 pruebas, 13 fallos y 5 errores,
  19 omitidas. Suite con fase 2: 661 pruebas, los mismos 18 casos fallidos y
  19 omitidas; ningún fallo nuevo. Logs en `/private/tmp/alice-phase2-baseline-tests.log`
  y `/private/tmp/alice-phase2-plugin-final-tests.log`. Los 6 problemas de la antigua
  comparación previa a Watchers siguen incluidos; los otros pertenecen al código
  de recados/compras incorporado posteriormente, y ya fallan en `0e0490e`.
- Pruebas específicas de Tasks/API/hook: 21, todas pasan (incluye validación de
  campos añadida después de la suite completa). Aprueba versiones estrictas,
  mantiene perfil/sesión, consume una sola vez, falla cerrada, retira tarjetas,
  bloquea efectos desconocidos (incluidos scripts de Watchers) y no repite continuaciones ambiguas.
- Límite de instrucciones: 2 pruebas pasan. La descripción detallada permanece
  en la herramienta; la sección del prompt es breve y cabe en el presupuesto.
- Modelo Swift real: 3 comprobaciones con harness macOS pasan, incluida precisión
  de enteros grandes, preservación de versión/sesión y contenido tratado como datos.
  XCTest iOS y UI no ejecutados: requieren simulador, no autorizado en este Mac.
- `npm run slash:check`: 52 comandos coinciden entre web/iOS.
- Compilación genérica para iPhone: pasa. Build firmado e instalado: 93, `2b8dc28`; APIs Tasks y Watchers reales devuelven
  200 sin crear datos de prueba. Firma e instalación se registran en el
  recibo del plugin y la revisión/build de la app; revisión visual y una Task real
  con el modelo permanecen pendientes. No se hicieron llamadas al modelo ni
  modificaciones de Gmail/pagos como pruebas.

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


## Despliegue solicitado (9 de octubre de 2026)

- Paso 1: iPhone `A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B` tenía build 87.
  Se compiló y firmó build **88**, revisión `8a3fd02`, se instaló y se leyó de
  vuelta mediante `devicectl device info apps`: build 88 confirmado.
  La firma en Documents falló por FinderInfo en AliceShare; el build temporal
  `/private/tmp/alice-watchers-device-build` completó correctamente. Sin simulador.
- Paso 2: backup `~/.hermes/backups/plugin-alice-20261009-133429`, parche comprobado
  y aplicado, conservando `_register_purchase_browser(ctx)`. Plugin habilitado,
  gateway reiniciado y confirmado mediante `hermes gateway status --deep`, luego
  dashboard reiniciado y puerto 9119 escuchando. GET sin sesión a Watchers devuelve
  401, como exige la autenticación. No se ha comprobado aún la pantalla autenticada.
- Paso 4: creado exactamente un watcher Gmail test pausado, 0 pendientes:
  **`4ae19f9cce5546adb661d9634108528b`**. Sin cron activado ni dry run/modelo llamado.
  Falta el consentimiento de Google y la ruta económica explícita del usuario.
  Se preparó OAuth con su cliente existente de Descargas; no se aprobó consentimiento.
- No se envió ningún correo, no se hicieron pruebas UI en el teléfono y no se
  configuró Bark. La creación no inicia trabajo hasta activarse explícitamente.
  Fase 2 no iniciada.


## Recuperación de regresión de instalación

El build 88 salió de una rama basada en `28f48c8` (main) que no contenía las
mejoras previas del teléfono. Un número superior de build no garantiza que se
conserve el código más reciente. El usuario identificó Settings, sidebar,
composer y header regresados. Se recupera **toda** la rama `claude/muse-parity`
(`18a214d`), descendiente de `claude/sidebar-settings-composer` (`1fc290c`),
que además coincide con `INSTALLED_FROM` del plugin antes de Watchers.
Se conservan ambas historias en un merge y las adiciones de Watchers.
No se reconstruyen esos controles de memoria ni se modifica el journal real.
La UI existente queda igual que `18a214d`, salvo el enlace de Watchers y su cliente.
La guía de instalación debe aplicar las reglas actuales de AGENTS: rama subida,
ancestría del origen instalado y lectura del build justo antes de instalar.


Resultado de recuperación: **build 89 instalado y leído de vuelta desde el iPhone**,
con revisión de código `4befbc1`, rama subida `codex/proactive-watchers`.
Antes de instalar se comprobó otra vez que el teléfono seguía en nuestro build 88.
La compilación firmada pasó y se abrió Alice sin ejecutar pruebas UI ni enviar
mensajes. Las 31 pruebas de Watchers pasan tras el merge. `ChatScreen`, `Composer`
y `Features/Shell` son idénticos a `18a214d`; Settings solo añade el enlace Watchers.
El watcher `4ae19f9cce5546adb661d9634108528b` sigue en el host, pausado.
No se volvió a instalar el plugin ni se alteraron su journal o su configuración.
La comprobación visual del teléfono sigue pendiente; el build no acredita esa UI.
Fase 2 sigue sin iniciarse.
