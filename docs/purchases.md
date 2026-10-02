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
3. **Buscar.** Busca en la tienda real: su buscador o categoría, registrado con
   `purchase_discover`. El catálogo Shop (`catalog_search`, `catalog_product`) solo
   dice en qué tiendas se vende algo cuando no se nombra ninguna; sus resultados no
   tienen comprobación de cesta y no se convierten en tarjetas.
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
6. **Elegir.** Abre una tarjeta y toca «Comprar con Alice». Una respuesta con
   palabras no elige: el agente pide que se toque la tarjeta. La elección envía
   un identificador que el chat oculta. Las
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

## Reglas tomadas de otros agentes de compra

De la guía de compras y pagos de Muse (compartida por la persona, octubre de 2026) se adoptan
tres reglas de comportamiento, en la skill y en el brief del recado: una sola pregunta por
turno, la que más cambia el resultado, con opciones solo si el conjunto es finito; apagar
suscripciones, pruebas y extras no pedidos antes del resumen; y decir cuándo una respuesta es
provisional (sin recomendar antes de que existan las tarjetas). Lo que Muse hace con su
monedero (tarjetas virtuales de un uso, Shop Pay, Link) o con el catálogo de Meta no tiene
equivalente en Hermes y no se copia.

Del playbook del navegador que Muse escribió para Alice (2 oct) se toman además: los datos
de envío que faltan se piden una sola vez, todos juntos y antes de abrir la tienda, y se
guardan (`errands.delivery_questions`); el brief del recado lleva esos datos y lo elegido, de
modo que no depende de la conversación; el vigilante de vueltas mide el estado de la página
(título y texto visible), no su dirección, porque en Prozis login, dirección y pago comparten
`checkout/index`; y un recado parado conserva su página dos horas, para que «Abrir
navegador» muestre lo que la tienda pide y «Seguir desde aquí» continúe con esa cesta.

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

## Any shop: the shop engine

`hermes-plugin/shop_engine.py` reads a shop without selectors from the model. It detects the platform from the page, not the domain, and answers in three tiers, each reporting how (`how`):

1. **Platform endpoints.** Shopify (`/products/<handle>.js`, `/cart/add.js`, `/cart.js`, `/search/suggest.json`) and WooCommerce (Store API `/wp-json/wc/store/v1/`): prices in minor units, stock and variants, no DOM.
2. **Structured data.** JSON-LD `Product`/`Offer` (each variant's own offer), microdata, `og:price`.
3. **DOM heuristics.** The shop's own search form or the usual search addresses, product links that carry a price, the variant by its words (select, radio, chip), the add button by its words (never one that says pay, buy now or checkout), the cart link, the cart line that names the product with its units and unit price, the amount next to «Total» that is not a subtotal, shipping or saving, and cookie banners (Cookiebot, OneTrust, Didomi, Usercentrics, generic).

When no basket can be read, the quote is the product page's price with `basis: "page"`; the card says it, and the errand confirms the price in its own basket (`purchase_check_cart`) before any approval. The total the person approves is always read from the checkout page by the plugin. Prozis keeps its observed adapter behind the same tools. `purchase_discover` takes `shop` and `query`; `purchase_verify`, `purchase_check_cart` and `checkout_request` need no selector (the old ones remain optional).

Tests: `tests/test_shop_engine.py` runs the engine in jsdom against three fictional shops (Shopify-like, WooCommerce-like, a shop on no platform with JSON-LD, a cookie banner, a size select, a cart page, a coupon and a checkout summary); `scripts/verify-shops.py` runs the same shops and a bank page in a real headless Chrome with every request intercepted, in CI. Neither proves a real shop: anti-bot pages, logins required to see prices and checkouts in opaque frames still fall back to the page price or to the person taking the browser.

## Trusted cart evidence and secure errands

The chat records formats from the shop DOM with `purchase_discover`. `purchase_verify` uses disposable browser contexts with no personal cookies, vault access or payment operation. A successful recipe also probes the remaining formats. Every found format must have a cart quote or a DOM-backed unavailability reason before `purchase_options` can show cards. Quotes bind product URL, variant, units, currency, origin and time; the server ignores model-written prices. Public coupons count only if the cart applies them, and shipping/remaining conditions stay separate. Cards paginate six per page.

The person chooses a format in its detail and edits units there, initially one. Old clients send no quantity marker and retain one. Quantity changes or quotes older than fifteen minutes trigger another disposable check. A real price change shows both amounts; an equal amount never asks for another acceptance. An old offer without evidence cannot start or retry a purchase.

`needs_login` keeps an errand and its choice while waiting. `login_request` is bound to profile, exact shop origin and the errand's own target/context; `/errands/{id}/access` is authenticated by the dashboard and uses no-store responses. The iPhone's existing secure sheet sends directly to this endpoint instead of the active chat socket. Login/create is explicit. Passwords go into that profile's Hermes vault, OTPs into its pinned form; neither goes into errands JSON, chat/tool results or logs. Duplicate answers consume one request once, and a persisted continuation survives service restart. `login_fill` targets only the owned page, and offered login metadata is filtered to that exact origin.

After login, `purchase_check_cart` reads the errand's real units and current price and binds them to its store session. `checkout_request` refuses absent/stale evidence and reads the final amount using `total_selector`; checkout items come from the chosen offer. Approval and the existing payment gates remain mandatory. The fixture script `scripts/verify-purchase-complete.py --agent` exercises GPT-6 Luna with a synthetic intercepted shop on an isolated Chrome port, fictional accounts and no payment operation. Native visual fixtures are behind the debug-only `-purchaseReview` argument and run in the Purchase review CI workflow.

Todo pago deja rastro en el libro de pagos del plugin (`purchases.py`), no solo el relleno de una tarjeta guardada: un clic que paga por sí mismo (el botón «Pagar», cualquier pulsación en la página del banco) se anota antes de ocurrir, y un resultado que el agente registra desde un recado con checkout aprobado se anota aunque ningún hook viera el pago (PayPal, Bizum, la tarjeta que guarda la tienda, la persona terminando en la página del banco). `checkout_request` lleva `payment_method`; solo `card` exige una tarjeta en la bóveda. Las guardias fallan cerradas: si la bóveda o el libro no se pueden leer o escribir, no se rellena ninguna tarjeta ni se pulsa pagar. El motor del recado no acepta «hecho» con un pago en el aire: pide `purchase_outcome` dos veces y, si no llega —o si el recado se para por cualquier motivo después de la aprobación—, lo cierra como `unknown` en el libro y en el recibo; la tarjeta dice «no está confirmado si el pago se hizo», nunca «no se ha pagado nada». Una tienda ya pagada (o con resultado desconocido) en las últimas 24 h para el recado con «Ya pagada»: solo «Es otro pedido: pagarlo» en la app permite un pago más, dentro de la ventana de aprobación. El cupón con el que se comprobó el precio viaja con la oferta y el recado lo aplica antes de comprobar la cesta.

Antes de rellenar una tarjeta o ejecutar una acción de pago, el servidor comprueba que la cesta del recado se comprobó en la última hora en ese mismo contexto de navegador y, si la página es la de la tienda, vuelve a leer el total visible del resumen vinculado a la aprobación. Si la tienda envió al recado a la página del banco o del proveedor de pago (Redsys, Stripe, Adyen…), el total de la tienda ya no está en pantalla: se acepta esa página porque muestra el paso de pago, y el registro de pagos impide pagar dos veces. Un cambio de importe o de contexto bloquea el pago hasta una nueva comprobación y aprobación; un fallo al comprobarlo también bloquea el pago. Las cookies no forman parte de la evidencia: cambian en cada página.

La elección de tarjeta al aprobar es vinculante: un relleno con otra tarjeta se bloquea. Las aprobaciones valen 20 minutos y un checkout espera 45 antes de caducar. Un recado que da muchos pasos en una misma página recibe primero un aviso para leer el error de la tienda; solo una segunda vuelta lo para. Una respuesta de la persona (aprobación, tarjeta, pregunta) se guarda en el recado y la lee el motor aunque el modelo todavía no hubiera terminado su turno.

# Correcciones de búsqueda y comprobación en Prozis

Para una petición de Creapure de Prozis, la búsqueda parte de la categoría completa,
no de un producto destacado en la portada. El servicio registra todos los formatos
Creapure, conserva la certificación pedida y rechaza preguntas de sustitución o formato
que intenten reemplazar las tarjetas comprobadas.

El adaptador de Prozis lee los controles actuales de la ficha y su cesta desechable:
selecciona el envase que corresponde a la ficha (80 cápsulas no se convierte en 320),
declara el sabor comprobado, usa el contador real y espera la confirmación del añadido.
Comprueba los cupones públicos observados; si requieren login, el descuento sigue siendo
una condición pendiente. El importe mostrado procede de la cesta, con envío separado.
Los totales de línea se convierten en importes por unidad usando la cantidad comprobada.

Regresión aislada, con Chrome y todas las peticiones de tienda interceptadas:
`python scripts/verify-prozis-purchase.py`; `--luna` ejecuta además GPT-6 Luna contra
esa tienda ficticia. No usa el gateway, el vault ni el navegador personal y no puede pagar.
