# Plan de trabajo — backlog 2026-09-20

Plan operativo para cerrar el backlog de bugs/features de Alice (iOS-first).
Escrito para que cualquier modelo/persona pueda continuar sin contexto previo.
Cada bloque: causa raíz verificada en código → cambio concreto (archivo:función) →
cómo verificar → cómo commitear. Sigue `AGENTS.md`; este Mac **no tiene simulador**:
la verificación local iOS es una build `generic/platform=iOS`.

## 0. Estado de partida y reglas

- Repo: `/Users/mfreixanet/alice` (GitHub `Freixanet/alice`). Rama actual:
  `fix/home-model-confirmation` sobre `9821f81`.
- Hay **cambios sin commitear** (menciones sin `@` en el composer + carpetas
  anidadas visibles en `NotesFoldersScreen`/`NotesScreen`/`AppStore`). Son
  trabajo válido y coherente: se commitean primero, tal cual, como
  `feat(ios): nested folders walk the tree; mentions route without @`.
- Hermes del usuario: `~/.hermes/hermes-agent` (b889e4e, 2026-09-14). Eventos
  del stream en `tui_gateway/contracts/events.py`. **`~/.hermes/config.yaml`
  tiene `display.interim_assistant_messages: false`** → el servidor NO emite
  `message.interim`. Es un dato clave para el bug 15.
- Build local (única verificación iOS posible aquí):
  ```bash
  xcodebuild -project ios/Alice.xcodeproj -scheme Alice -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath ios/.build/DeviceData \
    -allowProvisioningUpdates build -quiet
  ```
  Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, **warnings = errores**.
  Si se añaden archivos Swift: `cd ios && xcodegen generate` (no commitear el .xcodeproj).
- Plugin Python: `python -m unittest discover -s hermes-plugin/tests`.
- Notifier Mac: `python -m unittest discover -s mac/notifier`.
- Reglas de diseño (`docs/design-system.md`): sin gradientes, sin sombras, sin
  glass, un acento a la vez, radio 8. "Color sin hacerlo cutre" = usar el acento
  del usuario con más presencia + colores semánticos de estado, no decoración.
- Un commit por bloque, mensaje `tipo(ámbito): qué`. No tocar `.env*`.
- No enviar prompts ni reiniciar el Hermes real del usuario en pruebas.

## 1. Orden de ejecución (por valor/riesgo)

| # | Bloque | Ítems del usuario | Riesgo |
|---|--------|-------------------|--------|
| 1 | Commit del WIP | carpetas anidadas (parcial) | bajo |
| 2 | Notas: banner "Note not saved" + margen inferior | 9, 10 | bajo |
| 3 | "Reconnecting to Hermes…" espurio | 20 | bajo |
| 4 | Mensajes intermedios visibles | 15 | medio |
| 5 | Etiquetas de actividad reales por tarea | 13 | medio |
| 6 | Modo desarrollador: llamadas/tokens por respuesta | 16 | bajo |
| 7 | Cambio de modelo lento | 17 | medio |
| 8 | Cola de mensajes acumulados | 18 | bajo (UX) |
| 9 | Bark avisa antes de tiempo | 19 | bajo |
| 10 | Sidebar lento | 5 | medio |
| 11 | Carpetas: orden (Edit como Notas) | 1, 2 | medio |
| 12 | Inbox funcionando | 3 | medio (depende de Hermes) |
| 13 | Accesos directos en home | 4 | medio |
| 14 | Adjuntos en notas | 11 | alto (servidor+cliente) |
| 15 | Color de la app | 7 | medio |
| 16 | Avatares de agentes | 8 | medio |
| 17 | Alice se auto-diagnostica | 14 | alto |
| 18 | Alice proactiva (investigación) | 12 | doc |
| 19 | Pasada manual de pulido | 6 | — |

## 2. Detalle por bloque

### B2. Notas — "The dashboard took too long to answer / Note not saved" y margen inferior
Causa: `NoteEditor.swift:122` autosave con debounce 1.2 s → `save()` → `store.editNote`
→ `DashboardClient` con timeout 15 s (`DashboardClient.swift:72`); cualquier fallo
pone `failure` y sale un `.alert` centrado (`NoteEditor.swift:134-142`) mientras escribes.
Cambios:
- `NoteEditor.swift`: el autosave **nunca** muestra alert. Guardar estado
  `saveState: .saved/.saving/.pendingRetry(Error)`; en fallo reintentar con
  backoff (2 s, 5 s, 15 s) y mostrar una línea discreta bajo el título
  ("Guardado" / "Sin conexión, se guardará"). El alert solo al pulsar **Done**
  o al salir si sigue sin guardar. Nunca perder el texto: el borrador queda en memoria
  y se reintenta al volver a primer plano.
- Debounce a 2 s; coalescer: si hay un save en vuelo, marcar `dirty` y encadenar.
- Margen: `NoteEditor.swift:320` `textContainerInset.bottom = 40` con
  `.ignoresSafeArea(.bottom)` (`:77`). Poner bottom inset = 64 (barra accesoria)
  + `safeAreaInsets.bottom` y actualizar `contentInset` con `keyboardLayoutGuide`.
Verificar: build; test unitario de la máquina de estados si se extrae a
`Models/NoteSaveState.swift`.

### B3. "Reconnecting to Hermes…" espurio
Causa: `AppStore.swift:6240` pone la nota al **primer** fallo de `turnSnapshot`
(`BotTurnWatch.checked(.failure)` → `.reconnecting` desde `failedChecks == 1`,
`BotTurnWatch.swift:195-208`). Un solo timeout de 20 s tras 30 s de silencio ya la muestra.
Cambios (`BotTurnWatch.swift` + test `BotTurnWatchTests`):
- `.reconnecting` solo cuando `failedChecks >= 2` **y** hay ≥ 45 s sin ningún frame;
  el primer fallo devuelve `.keepWaiting`.
- Al recibir cualquier frame del turno, limpiar la nota (ya se hace en `.keepWaiting`).
- No desconectar el socket por un `NoAnswer` aislado (`AppStore.swift:6222-6226`):
  solo a partir del segundo fallo consecutivo.

### B4. Mensajes intermedios que desaparecen
Causa: modelo de "una burbuja por turno". `tool.start` borra el texto acumulado
(`AppStore.swift:6138-6141`); `message.interim` se ignora (`:6730-6733, :6821`);
además el servidor no lo emite (config `interim_assistant_messages: false`).
Cambios:
- `Models/Chat.swift` `ChatEvent`: añadir `.interim(text:)`.
- `AppStore.chatEvent(from:)`: mapear `message.interim` → `.interim`.
- `AppStore.apply`: en `tool.start`, si el placeholder tiene texto no vacío,
  **sellarlo** como mensaje asistente independiente (nuevo id, `interim: true`)
  y crear un placeholder nuevo para lo que venga después; no borrar.
  En `.interim(text)`: si `already_streamed` no aplica al cliente, sellar igual
  (dedupe por texto normalizado contra el último sellado).
- `Message`: campo opcional `interim: Bool` (Codable con default; leer archivos
  antiguos → test en `ConversationArchiveTests`).
- `BotChatSession.swift` merge: no descartar filas asistente intermedias (solo
  las vacías, como ahora); casar selladas locales con las canónicas por texto.
- Doc: `docs/getting-connected.md` — recomendar `display.interim_assistant_messages: true`
  en Hermes para ver comentarios intermedios (Alice funciona igual sin él gracias al sellado en `tool.start`).

### B5. Etiquetas de actividad reales
Causa: `ToolCaption` (`MessageRow.swift:592-712`) usa una lista fija `musings` sembrada
por id de mensaje y un mapa por **nombre** de herramienta. Se ignoran `status.update`,
`tool.start.context/args/preview`, `todo.updated`, `subagent.*` (`AppStore.swift:6821-6827`).
Cambios:
- `ChatEvent.tool` pasa a llevar `context`, `argsText/preview` (ya vienen en
  `ToolStartPayload`). Nuevo `ChatEvent.status(kind:text:)` desde `status.update`.
- `ToolCaption.headline`: prioridad → `status.update.text` reciente > frase derivada de
  tool + argumento concreto ("Leyendo `NoteEditor.swift`", "Buscando: precio iPhone 17",
  "Ejecutando `npm test`") > nombre genérico. Nunca la lista aleatoria mientras haya
  actividad real; `musings` solo antes del primer evento.
- Live Activity (`AgentActivities.swift`) recibe la misma línea (ya comparte `headline`).
- Tests en `ToolCaptionTests`.

### B6. Modo desarrollador — llamadas y tokens
Dato: `message.complete.usage` (`Usage{model,input,output,reasoning,total,calls,...}`)
ya llega y se ignora; `tool.start` se puede contar en cliente.
Cambios:
- `Message`: `usage: MessageUsage?` (Codable opcional).
- `AppStore.apply(.complete)`: guardar `usage`; contar `tool.start` por turno en
  `toolCallsByReply[replyID]`.
- Ajuste `developerMode: Bool` (`Keys.developerMode`) en Settings › Advanced.
- `MessageRow`: con developerMode, línea mono bajo la respuesta:
  `model · N llamadas LLM · N herramientas · in/out/reasoning tokens · t s`.
  `latencyStartedAt` ya existe para la duración.
- `session.usage` (tick a mitad de turno) opcional para actualizar en vivo.

### B7. Cambio de modelo lento
Causa: `setBotModel` (`AppStore.swift:1743-1863`) espera al sync anterior completo
(`:1754-1791`), luego `profiles.configure`; `carryModelChange` hace N RPC en serie
(`:1996-2020`). El picker mantiene `applyingModel` hasta que vuelve.
Cambios:
- No esperar al sync anterior: cancelarlo (`botModelSyncTasks[bot]?.cancel()`) y
  arrancar el nuevo (el último cambio gana). Guardar el modelo objetivo para que
  el sync viejo no pise el nuevo.
- `ModelPicker.applyBotModel`: aplicar optimista → cerrar el picker en cuanto
  `profiles.configure` responde (ya casi es así); mostrar chip "Sincronizando rutinas…"
  no bloqueante. Si `profiles.configure` falla, revertir y avisar.
- `carryModelChange`: rutinas en paralelo con `withThrowingTaskGroup`; `switchOpenBotChat`
  solo si el chat está abierto.

### B8. Cola acumulada
Causa: comportamiento de Hermes `display.busy_input_mode` (queued/steer) — no hay cola
en el cliente. Es correcto pero opaco.
Cambios (solo UX):
- Mostrar en el composer un aviso claro cuando la disposición es `.queued`/`.foldedIn`
  con acción **"Cancelar envío"** (`prompt.cancel`/`interrupt` si el gateway lo expone —
  comprobar `tui_gateway/contracts` `methods_*`; si no existe, permitir borrar el
  mensaje local antes de que empiece).
- Documentar en Settings › Agente la opción `busy_input_mode` (steer/queue/interrupt).

### B9. Bark avisa antes de la respuesta
Causa: `mac/notifier/alice_notifier.py:classify` avisa en la primera fila
`role=assistant, finish_reason='stop'`, que también escriben los mensajes intermedios.
Verificado en `~/.hermes/state.db`: filas `stop` seguidas de más filas assistant/tool.
Cambios:
- `assistant_rows`: además, comprobar que la sesión no tiene actividad posterior:
  la fila es final si es la última de su sesión **y** han pasado ≥ `SETTLE_SECONDS`
  (8 s) desde su timestamp, o si la siguiente fila es `role='user'`.
- Mantener un `pending` en `state.json` para filas vistas pero no asentadas; avisar
  en la pasada siguiente si siguen siendo la última.
- Tests en `mac/notifier/test_*.py` (fila intermedia no avisa; final sí).

### B10. Sidebar lento
Causa: `Sidebar.body` se reevalúa cada frame del gesto (`surfaceProgress`), con
`.mask(edgeFade)` sobre toda la lista (`Sidebar.swift:42,218-263`), filtros
`pinned/recents` sin cache (`:326-327`), `titleStyled` dos veces por fila, `glassEffect`.
Cambios:
- Separar la lista en `SidebarList` (subvista) que **no** recibe `surfaceProgress`;
  solo el header/overlay dependen del progreso.
- Reemplazar `.mask(edgeFade)` por dos `LinearGradient` superpuestos con
  `.allowsHitTesting(false)` (compositing barato) o quitar el fade.
- `pinned`/`recents` cacheados en `AppStore` (recalcular al cambiar `conversations`).
- Preview del contextMenu: `Text(conversation.title)` plano.
- `loadProjects()` no en `.task(id:)` cada apertura: cachear 60 s.

### B11. Carpetas: orden (Edit, como Notas)
Base: nesting ya funciona. Orden = `noteFolderOrder` en defaults (cliente).
No hay pin de carpetas, ni arrastre libre para anidar, ni botón de ordenar.
Cambios:
- `NotesFoldersScreen`: a la derecha de New Folder, **Edit** → **checkmark**.
  En edit mode, List `.onMove` muestra el handle de tres rayas solo en las
  carpetas propias (no Quick Notes / All Notes / Recently Deleted). Arrastrar
  por el handle intercambia con la vecina; `UIImpactFeedbackGenerator(.light)`
  en cada hop. `NoteFolderTree.reorderingDisplayed` reescribe solo hermanos.
- Tests `NoteFolderTreeTests`: swap con la de debajo; anidadas se quedan con
  su padre.

### B12. Inbox
"Inbox" = perfil Hermes que tiene `workspace/inbox-store/inbox.py`; sin él Notes
muestra "No notes agent" (`plugin_api.py:769-782`, `NotesScreen.swift:644`).
Pasos:
1. Diagnóstico real: `ls ~/.hermes/profiles/*/workspace/inbox-store/` y llamar a
   `GET api/plugins/alice/notes` con el dashboard en marcha para ver `available`.
2. Si falta el store: `hermes-plugin/install.sh` / README paso "notes agent"; si el
   perfil no se llama `inbox`, `_notes_store()` debe recordar el elegido
   (guardar en `~/.hermes/.alice/notes_store.json`) en vez de "el primero que encuentre".
3. Cliente: `AppStore.refreshNotes` distingue *no store* / *offline* / *401* con
   textos y acciones distintas (botón "Crear agente Inbox" que lanza la plantilla
   de agente con el store).
4. Test `test_plugin_api.py`: store elegido persiste entre peticiones.

### B13. Accesos directos en home
No existe ninguna superficie de atajos. Home = `EmptyChatView` (`ChatScreen.swift:656-733`).
Cambios:
- `Models/HomeShortcut.swift`: `Target { destination, note, noteFolder, bot, artifact, conversation }`,
  `label`, `symbol`. Persistido JSON en `Keys.homeShortcuts` (patrón `botChannels`).
- `AppStore.openHomeShortcut(_:)` junto a `goHome()`; para nota/carpeta añadir
  `requestedNote: String?` que `RootView` consume abriendo Notes con ese scope.
- UI: fila/rejilla compacta bajo el saludo del home (estilo del pinned shelf de
  `BotsScreen.swift:546`), modo edición con reordenar y quitar.
- Añadir "Añadir a la home" en menús contextuales de nota, carpeta, agente, chat, artefacto.

### B14. Adjuntos en notas
Servidor solo guarda texto+RTF (`plugin_api.py:899-984`). Recomendado servidor+cliente:
- `plugin_api.py`: `attachments: [{id,name,mime,kind,data_b64}]` en `_EditedNote`/`_add_note`,
  tope 8 MB por nota (`NOTE_ATTACHMENTS_MAX_BYTES`), persistir en `entries.jsonl`,
  emitir en `_note_payload`. Test en `test_notes_tools.py`.
- `Models/Note.swift`: `attachments: [Attachment]?` (reutiliza `Chat.Attachment`).
- `NoteEditor`: botón adjuntar → `AttachmentLoader` (`AttachmentPicker.swift`) →
  `AttachmentChips`; incluir en `save`. `NoteAttachmentsScreen`: primero adjuntos reales, luego enlaces.
- Fallback si el plugin es viejo: adjuntos locales en `NotesSnapshot` cache y aviso
  "Actualiza el plugin para sincronizar adjuntos".

### B15. Color
Hoy: neutro + un acento (`Theme.swift`). Sin romper reglas:
- Acento con más presencia: botón enviar, selección, iconos de sección, título del
  agente en chat, chips de estado.
- Colores semánticos (`Palette.success/warning/danger/info(scheme)`) usados solo para
  estado (guardado, fallo, rutina fallida, cola).
- Cada agente ya tiene su color (`BotMark.colours`): usarlo en su cabecera de chat
  y en su fila del drawer (línea de 2 pt a la izquierda, no fondo).
- Nada de gradientes/sombras/glass. Revisar AA en claro/oscuro.

### B16. Avatares de agentes (Muse-style, dioses griegos)
Persistencia intacta: `BotMark{colour:Int, shape:Int}`. Cambiar solo el renderer.
- `Models/BotSymbolMark.swift`: catálogo de 12 símbolos de línea (SF Symbols o Path)
  con nombre de dios: Hermes (caduceo/alas), Atenea (búho), Apolo (lira/sol),
  Artemisa (luna/arco), Hefesto (martillo), Deméter (espiga), Poseidón (tridente),
  Hestia (llama), Iris (arco), Mnemósine (pergamino), Dédalo (laberinto), Clío (pluma).
  Indexado por `shape` (extiende el rango, sigue siendo Int).
- `BotMarkView`: disco plano del color del bot (sin gradiente) + símbolo en trazo
  fino, monocromo, alto contraste; `AnimatedBotMarkView` conserva la animación sutil.
- Selector en la ficha del agente: elegir símbolo + color. Live Activity sigue
  funcionando (usa `colour/shape` Int).

### B17. Alice se auto-diagnostica
Hoy Hermes no puede leer nada de la app. Plan mínimo:
- iOS `AppStore.pushDiagnostics()` al volver a primer plano y tras cada error de turno:
  POST cola de últimas 200 líneas de `DiagnosticsLog` + `appStateSummary()`
  (conexión, wellbeing, versión, eventos desconocidos) a
  `POST api/plugins/alice/app/diagnostics`.
- `plugin_api.py`: endpoint que guarda por dispositivo en `~/.hermes/.alice/diagnostics/`.
- `hermes-plugin/__init__.py`: toolset `alice_debug` con `alice_app_status()` y
  `alice_recent_errors()`; prompt section con guía de causas frecuentes
  (`docs/request-lifecycle.md`). Así, "Alice, ¿qué va mal?" puede responder con datos.
- Slash `/debug` en la app que envía el resumen al chat actual.

### B18. Proactividad (investigación → `docs/radar-ia.md` o nuevo `docs/proactive.md`)
Ya existen cron (`RoutinesScreen`, `RoutineBrief.templates`), eventos (`EventDigest`),
Live Activity, canales, webhooks. Propuesta:
1. "Sugerencias" en home: función pura sobre rutinas fallidas, chats sin responder,
   notas con `openQuestions`, usage alto → `AliceEvent`.
2. Rutina "briefing diario" con plantilla existente + permiso de notificación.
3. Hermes: heartbeat/`status.update kind: heartbeat` ya existe; evaluar `cronjob` con
   `deliver: bot-chat` para que Alice inicie conversación.
4. Límite: iOS no permite always-on; Bark/Live Activity son el canal.

### B19. Pasada manual
Con la app instalada en el iPhone: checklist en `docs/verification.md` — abrir drawer,
crear/mover/ordenar carpetas, escribir nota 2 min sin alertas, adjuntar imagen,
cambiar modelo (< 2 s cierre), enviar con el bot ocupado, apagar wifi 20 s a mitad de
respuesta, notificación Bark tras respuesta final, avatar y color en claro/oscuro.

## 3. Registro de progreso

Actualizar esta tabla al cerrar cada bloque (commit + estado de verificación).

| Bloque | Estado | Commit | Verificación |
|--------|--------|--------|--------------|
| 1 WIP | hecho | 28bbf48 | build device + install |
| 2 Notas | hecho | 45add6b | build device + install; unit tests escritos, no corridos aquí |
| 3 Reconnecting | hecho | ee2ed06 | build device + install; unit tests escritos, no corridos aquí |
| 4 Interim | hecho | f9919ed | build device + install; unit tests escritos, no corridos aquí |
| 5 Captions | hecho | 63c326a | build device + push; install pendiente (iPhone unavailable) |
| 6 Developer | hecho | bc3b26f | build device + push; install pendiente (iPhone unavailable) |
| 7 Model sync | hecho | 6d855cb | build device + push; install pendiente (iPhone unavailable) |
| 8 Queue UX | hecho | b78ee8e | build device + push; install pendiente (iPhone unavailable) |
| 9 Bark | hecho | bb49b50 | python -m unittest discover -s mac/notifier |
| 10 Sidebar | hecho | b172df0 / f587753 | build device + install; unit tests escritos, no corridos aquí |
| 11 Carpetas | hecho | 92a5f3d | build device + install; unit tests escritos, no corridos aquí |
| 12 Inbox | hecho | 5e85b58 | plugin tests + build device + install |
| 13 Accesos home | hecho | bb1062f | build device + install; unit tests escritos, no corridos aquí |
| 14 Adjuntos | hecho |  | plugin tests + build device + install; unit tests escritos, no corridos aquí |
| 18 Sugerencias | hecho |  | build device; unit tests escritos, no corridos aquí. No crea un briefing sola |
