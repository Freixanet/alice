# Auditoría de ejecución nativa de Alice — 30 de septiembre de 2026

Objetivo: conservar Alice y mejorar la calidad de sus interacciones diarias. No se asigna una nota frente a apps de 2027 que todavía no se han podido observar.

## Evidencia y alcance

Revisión del código actual de GitHub, dos capturas de la conversación del 30 de septiembre, y segunda revisión del diff. Las capturas muestran la versión anterior, no el resultado de esta rama. La base es el PR #38 (`8ac7975`): sus correcciones de duplicados, progreso y cabecera no se vuelven a implementar.

Revisión principal: navegación y drawer, Inicio, chat, composer, feed, Agenda, tarjetas de encargos y controles compartidos. Revisión adicional de estados y movimiento: Agentes, Notas, Rutinas, Actividad y Ajustes. No se ha recorrido visualmente cada pantalla o cada estado de la app.

## Hallazgos por impacto

| Prioridad | Evidencia                                                                                                                    | Corrección                                                                                                                            |
| --------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| P0        | Las capturas muestran texto bajo el avatar y varias tarjetas del mismo encargo.                                              | Ya resuelto en la base del PR #38. Se conserva esa solución.                                                                          |
| P1        | Controles de 22–34 pt en Agenda y composer; varios textos interactivos pequeños.                                             | Áreas de 44 pt en los controles revisados. Se conserva el tamaño de los glifos del composer compacto.                                 |
| P1        | Inicio fija tres accesos de 96 pt más separación, incluso con pantalla estrecha o letra grande.                              | Grid adaptativo, anchura escalada y etiquetas que pueden crecer. Inicio puede desplazarse si no cabe.                                 |
| P1        | Navegación, envío, expansión, tarjetas de compra y filas de Notas/Agentes ignoran parcialmente Reducir movimiento.           | Transiciones programáticas sin desplazamiento cuando está activado; los gestos siguen al dedo. El indicador en directo se queda fijo. |
| P1        | Las tarjetas de Agentes se comprimen al 90 %, con rebote propio.                                                             | Reutilizan el feedback compartido, más contenido y compatible con Reducir movimiento.                                                 |
| P1        | El feed vacío no explica qué sucede. Una generación fallida no muestra el motivo.                                            | Estados de carga, vacío, error y offline con un siguiente paso. El contenido guardado permanece.                                      |
| P1        | Varias peticiones rápidas pueden pedir más de una generación. Un watcher cancelado puede borrar la referencia del siguiente. | Guard de petición en curso/activa y token de identidad para el watcher. Recuperación al volver al primer plano.                       |
| P1        | La barra Deshacer tapa el último contenido. El editor puede perder cambios al cerrarse.                                      | Inset inferior que reserva espacio; confirmación al descartar e imposibilidad de cerrar/editar durante el guardado.                   |
| P1        | Las citas usan el acento del sistema y pueden confundirse con el texto.                                                      | Color semántico de enlaces de Alice en ambos temas.                                                                                   |
| P2        | Paso actual del plan, contexto del navegador y errores de Rutinas se cortan demasiado pronto.                                | Más líneas o altura intrínseca, sin ocultar el motivo del fallo.                                                                      |
| P2        | La hoja de explicación del feed no permite desplazar texto largo.                                                            | Scroll nativo y papel consistente con Alice.                                                                                          |

## Criterios visuales

| Aspecto                             | Decisión                                                                                                                                                          |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Jerarquía y densidad                | Mantener conversación como centro; mejorar la información de estado antes de cambiar tamaños arbitrariamente.                                                     |
| Spacing y alineación                | Una altura de control compartida en el composer; accesos que caben en el ancho real; espacio real para Deshacer.                                                  |
| Tipografía                          | Conservar Instrument Serif y texto del sistema; permitir crecimiento en las zonas corregidas.                                                                     |
| Contraste                           | Citas: 5,34–5,79:1 sobre las superficies claras y 7,67–8,28:1 sobre las oscuras, calculado a partir de los colores opacos. No equivale a medir glass renderizado. |
| Profundidad y materiales            | Conservar glass en controles y papel en contenido. No añadir gradientes, brillos, sombras ni otra capa decorativa.                                                |
| Coherencia, selección e iconografía | Reutilizar PressableCardStyle; mantener SF Symbols y acciones en el mismo lugar; feedback de pulsación sin una segunda superficie.                                |
| Equilibrio visual                   | No cambiar avatar, paleta, estructura de navegación ni composición central sin evidencia de pantalla.                                                             |

## Interacción y movimiento

Se preservan el seguimiento del transcript, la separación entre pulsar Enviar y cerrar el teclado, los borradores, la identidad de cada agente y los contratos de aprobación. No se cambian modelos, pagos, credenciales ni datos de conversación.

La ampliación de los controles conserva el glifo dentro de su área táctil. Enviar, Detener y Voz comparten el mismo sitio. Las animaciones modificadas responden a una acción o estado concreto. Reducir movimiento quita pulsaciones repetidas, rebotes y desplazamientos programáticos; no retrasa la retirada de una pantalla ya cerrada. Las expansiones no animan cada modificación del plan completo.

## Matriz de estados

| Estado                       | Evidencia de esta revisión                                                                    | Pendiente en pantalla                                        |
| ---------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Initial / loading            | Feed e Inicio tienen contenido o explicación; se conservan los loaders existentes.            | Primer arranque, con y sin emparejamiento.                   |
| Empty / populated            | Estado vacío explícito; se conserva la lista de posts y mensajes.                             | Feed vacío real y listas pobladas en ambos temas.            |
| Partial                      | Se mantienen los estados parciales de Rutinas y las respuestas parciales del chat.            | Composición visual durante una respuesta o lectura parcial.  |
| Error / offline / retry      | Motivo visible, cache conservada, retry y solicitudes de generación acotadas.                 | Desconectar/reconectar con contenido existente.              |
| Disabled / temporal          | Se mantienen los guard de envío/pago; feedback sin pérdida de la identidad del botón ocupado. | VoiceOver, spinner y estado disabled con cada acento.        |
| Background / foreground      | El feed pausa su vigilancia y vuelve a sincronizar; un watcher antiguo no retira el nuevo.    | Bloqueo/desbloqueo y retorno desde otra app.                 |
| Contenido largo / extremo    | Inicio desplazable, accesos adaptativos, explicación desplazable y textos menos truncados.    | Mayor tamaño accesible, textos extremos y pantalla estrecha. |
| Destructivo / interrupciones | Deshacer reserva espacio; editar el brief exige descartar explícitamente.                     | Borrar/deshacer sucesivamente y navegación interrumpida.     |

## Verificación

- `git diff --check`: correcto.
- Catálogo de localización: JSON válido; nuevas etiquetas e instrucciones con traducción española.
- Tres regresiones de FeedStore añadidas: una sola generación ante solicitudes concurrentes, retry después de fallo sin perder posts y reemplazo del watcher cancelado. Definidas; la ejecución se documenta en el PR.
- Compilación nativa y `build-for-testing` con Xcode 26.5, destino genérico iOS, en una copia aislada: correctos. Compilar las pruebas no equivale a ejecutarlas.
- No se ejecutan simuladores ni UI tests en el Mac personal, conforme a AGENTS.md. Las suites de simulador quedan para CI.
- No se instala esta rama en el iPhone ni se envían pruebas al Hermes real.

## Segunda revisión crítica

Se corrigió el tamaño táctil del tick de Agenda, se conservó el tamaño visual de los botones compactos al ampliar su alcance y se retiró una atenuación global que podía apagar también los spinners de operaciones en curso. Se corrigieron los textos nuevos para español y se reutilizó el estilo de presión ya existente en Agentes.

La limitación pendiente es material: una compilación no demuestra equilibrio, contraste del glass, timing, gestos o teclado en el iPhone. Para cerrar la auditoría visual se necesitan capturas actuales y un recorrido de los estados de la tabla. Esta rama no se presenta como una revisión visual completa ni como una versión lista para publicar.

La comprobación de seguridad previa a publicar detectó avisos en `brace-expansion`. Se actualizan únicamente las dos entradas de desarrollo del lockfile, de 1.1.18 a 1.1.21 y de 5.0.9 a 5.0.12; no cambia package.json ni el código del producto web.
