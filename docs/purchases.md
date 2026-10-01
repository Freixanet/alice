# Comprar con Alice

La compra se divide entre el chat, donde se decide qué comprar, y un recado de
Hermes, que prepara el pedido y espera la aprobación antes de pagar.

Los recados usan GPT‑6 Luna (`gpt-6-luna`, proveedor `openai-codex`) por ahora.
Guardan esa selección al crearse y la conservan al reanudarse; el modelo del
chat no cambia. La configuración está en el [plugin](../hermes-plugin/README.md#fixed-model-for-errands).
Los precios y totales se validan como céntimos y moneda al entrar. Un importe
negativo, ambiguo o con monedas contradictorias no puede ofrecerse ni aprobarse.
El navegador gestionado se prepara antes de iniciar una ejecución del modelo.
Si el arranque falla, se informa y se permite volver a intentar la compra. Una
mención al mismo precio elegido no se muestra como «Precio distinto». Un precio
antiguo tachado no sustituye la comprobación del importe en la cesta.
La configuración YAML usa la biblioteca de la versión instalada de Hermes.
Cada recado conserva su sesión y contexto de navegador, incluidas las nuevas
pestañas y la recuperación de pestañas, para no compartir cookies ni cestas con
otros recados. Las capturas imprimen su ruta para que Hermes pueda adjuntarlas
al resultado de la herramienta. Leer controles de pago no exige aprobar un pago;
las acciones que pueden enviarlo y el relleno de la tarjeta siguen protegidos.

1. **Aclarar.** Alice pregunta antes de buscar si falta talla, modelo, variante o
   cantidad. Las respuestas cerradas aparecen como botones punteados o rellenos.
2. **Contexto.** Usa país, moneda, dirección, tiendas anteriores y etiquetas de
   tarjetas guardadas. Los números de tarjeta nunca pasan por el chat.
3. **Buscar.** Consulta el catálogo Shop (`catalog_search`, `catalog_product`) y
   la tienda real. El catálogo se consulta sin instalar herramientas ni iniciar
   sesión; no puede comprar. Si falla, Alice puede buscar en la tienda.
4. **Verificar.** El agente comprueba la página, el stock y el precio en la moneda
   de la persona. `purchase_options` valida esos datos y descarta opciones sin
   nombre, URL HTTPS, precio, moneda o stock declarado. Esa validación de campos
   no sustituye la comprobación de la página por el agente.
5. **Mostrar.** De una a seis tarjetas muestran foto, producto, variante, tienda
   y precio, con una recomendación. La app carga la lista aceptada por el plugin,
   no los argumentos sin validar del modelo. Si se pide una marca o tienda, no
   se rellena la lista con otras marcas: una sola coincidencia es válida. El plugin
   filtra las identidades explícitas que reconoce en la petición (por ejemplo
   «de Prozis»); las peticiones complejas también requieren que el modelo respete
   las instrucciones. La petición se conserva por chat durante tres días.
6. **Elegir.** Abre una tarjeta y toca «Comprar con Alice», o indica tu elección
   con palabras. La elección envía un identificador que el chat oculta. Las
   opciones pertenecen a su sesión, caducan a los tres días y una selección no
   altera las mismas opciones de otro chat. El turno interno de selección no ocupa
   una fila vacía, pero se conserva para separar los turnos y alojar el recado
   cuando todavía no hay respuesta.
7. **Preparar.** El recado aparece bajo la elección y en Recados. Recibe la página,
   variante, cantidad y precio elegidos. Prepara carrito y envío; debe parar si
   el producto deja de estar disponible o cambia lo elegido. Las acciones de
   carrito reconocidas por el plugin se bloquean en el chat.
8. **Tarjeta.** Antes del resumen, el plugin comprueba si hay una tarjeta guardada.
   Si falta, la app muestra el formulario seguro y el recado espera.
9. **Resumen.** La app escribe producto, variante, cantidad, envío, dirección,
   email, tarjeta y total a partir de los datos del checkout del recado.
10. **Aprobar.** Una tarjeta compacta permite elegir tarjeta, revisar el navegador,
    cancelar o pagar el importe exacto. Face ID o el código confirma la decisión.
    El servidor vincula la aprobación al checkout y conserva su total. Un checkout
    caducado necesita preparación y aprobación nuevas.
11. **Pagar.** El recado debe volver a comprobar el importe de la página. Si cambia,
    pide otra aprobación. El registro de pagos impide repetir un pago cuyo
    resultado aún no se conoce.
12. **Resultado.** La app muestra el pedido, número, total, tarjeta y entrega. Un
    pago rechazado y uno sin confirmar tienen mensajes distintos. Si la compra
    se detiene después de aprobarla, no se afirma que no hubo cargo: primero hay
    que comprobar el pedido.

## Límites y pruebas

Las instrucciones del agente están en `hermes-plugin/skills/comprar/SKILL.md`.
El plugin impone validaciones, pertenencia a sesión y las barreras de aprobación;
la comprobación visual del producto, el stock y el importe sigue dependiendo del
modelo y de las páginas de la tienda. No es una garantía de compra automática.

Developer › Components incluye opciones, elección, resumen y resultados de éxito,
rechazo, incertidumbre y falta de stock. Purchase walkthrough recorre los doce
pasos, espera la elección y la aprobación, y permite simular resultados distintos.
Ambos usan un store aislado sin conexión a Hermes.

Los tests del plugin usan fixtures. Los tests nativos cubren claves compartidas,
identificadores ocultos, colocación del recado, archivos anteriores y mensajes de
pago incierto. Este Mac no tiene simulador: compila para iPhone físico y puede
compilar los bundles de tests, pero no ejecuta las suites iOS ni compras reales.

La prueba explícita `scripts/verify-purchase-browser.py` usa el `browser_exec` real
de Hermes con Chrome temporal en otro puerto y productos ficticios. Comprueba el
arranque en frío, las cestas aisladas y la apertura de nuevas pestañas. El resumen,
la aprobación exacta y el recibo se ejercitan con fixtures; no se visita ninguna
tienda ni se paga. Véase [verificación](verification.md#purchase-browser-integration).

## Trusted cart evidence and secure errands

The chat records formats from the shop DOM with `purchase_discover`. `purchase_verify` uses disposable browser contexts with no personal cookies, vault access or payment operation. A successful recipe also probes the remaining formats. Every found format must have a cart quote or a DOM-backed unavailability reason before `purchase_options` can show cards. Quotes bind product URL, variant, units, currency, origin and time; the server ignores model-written prices. Public coupons count only if the cart applies them, and shipping/remaining conditions stay separate. Cards paginate six per page.

The person chooses a format in its detail and edits units there, initially one. Old clients send no quantity marker and retain one. Quantity changes or quotes older than fifteen minutes trigger another disposable check. A real price change shows both amounts; an equal amount never asks for another acceptance. An old offer without evidence cannot start or retry a purchase.

`needs_login` keeps an errand and its choice while waiting. `login_request` is bound to profile, exact shop origin and the errand's own target/context; `/errands/{id}/access` is authenticated by the dashboard and uses no-store responses. The iPhone's existing secure sheet sends directly to this endpoint instead of the active chat socket. Login/create is explicit. Passwords go into that profile's Hermes vault, OTPs into its pinned form; neither goes into errands JSON, chat/tool results or logs. Duplicate answers consume one request once, and a persisted continuation survives service restart. `login_fill` targets only the owned page, and offered login metadata is filtered to that exact origin.

After login, `purchase_check_cart` reads the errand's real units and current price and binds them to its store session. `checkout_request` refuses absent/stale evidence and reads the final amount using `total_selector`; checkout items come from the chosen offer. Approval and the existing payment gates remain mandatory. The fixture script `scripts/verify-purchase-complete.py --agent` exercises GPT-6 Luna with a synthetic intercepted shop on an isolated Chrome port, fictional accounts and no payment operation. Native visual fixtures are behind the debug-only `-purchaseReview` argument and run in the Purchase review CI workflow.
