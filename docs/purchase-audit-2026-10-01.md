# Auditoría del proceso de compra — 1 oct 2026

## Estado (misma fecha, rama `claude/purchase-audit`)

Todo lo de A a D está corregido en esta rama, atacando la causa y no el síntoma. Las causas
eran tres: (1) las puertas del pago exigían que el navegador no cambiara (cookies, origen,
pestaña, selector) cuando cambia en cada paso; (2) el motor perdía o mataba recados por
señales que no distinguen «atascado» de «avanzando»; (3) heurísticas de texto que convertían
peticiones normales en errores. Cada corrección lleva su test; los nombres están en la
sección correspondiente y abajo, en el mapa de los 18 problemas históricos.

| Causa | Qué cambia | Dónde |
|---|---|---|
| Evidencia atada al estado del navegador (A1, A2, A3, C7) | La cesta comprobada vale una hora y se ata **solo al contexto del navegador** y a la oferta; el total se relee en la tienda, y en la página del banco o del proveedor (pasarela conocida o página con paso de pago) se acepta porque el total de la tienda ya no está. Aprobación 20 min, checkout 45 min. | `purchase_prices.fresh_cart`, `payment_ready`, `errands.APPROVAL_TTL/CHECKOUT_TTL` |
| Señales de bucle que no distinguen avanzar de girar (A4) | La primera vuelta en una página avisa al agente y sigue; solo la segunda para. | `errands.circling`, `Engine.run` |
| Respuestas de la persona perdidas (A5) | Toda respuesta se guarda en el recado (`resume_message`) y el motor en marcha la envía como siguiente mensaje, también tras un reinicio. | `errands.resume`, `Engine.run` |
| Texto literal como prueba (B2, B5, B3, B4) | Comparación por palabras normalizadas (acentos, espacios, «500 g»/«500g»); identidad nunca es una cantidad; «pídeme cita» no es compra; cupones sin campo no rompen; el error nombra el selector. | `purchase_prices.names`, `purchase_flow.requested_identity`, `NOT_A_PURCHASE`, `purchase_prozis.plain` |
| Interacción extra (C1–C6) | Login opcional junto a «invitado» no se pide; «Ahora no» sigue como invitado; una pestaña recargada no invalida el login; la tarjeta elegida es vinculante; un toque cuya recomprobación falla arranca igual; aceptar un precio no exige otra comprobación; elegir método de pago no es pagar; `import time/json/re` permitidos. | `errand_access`, `__init__._guard_errand`, `_start_purchase`, `errands.is_pay_action` |
| Promesas falsas (A6, B1) | Skill, docs y descripciones dicen lo que el código hace: se elige tocando; el catálogo solo dice dónde se vende. | `SKILL.md`, `docs/purchases.md`, `README.md` |
| iOS (D1–D3) | Ids 7+, marcador de unidades oculto, perfil del recado para la tarjeta. | `PurchaseChoice.swift`, `Errand.swift`, `ErrandBoard.swift` |

Sigue pendiente de E: `purchase_outcome: unknown` deja el recado al juez (correcto: hay que
comprobar el pedido) y la comprobación en serie de formatos tiene ahora un presupuesto de 90 s
en vez de ser asíncrona.

### Capturas del 2 oct (02:23–02:26), con el plugin anterior a esta rama

| Visto | Causa | Cambio |
|---|---|---|
| El paso «Abrir la ficha…» aparece dos veces en la tarjeta del recado | La lista desplegada incluía la etapa en curso, que ya es la línea de estado con su spinner | `Errand.earlierStages`; test `testTheStageUnderWayIsNotListedTwice` |
| La tarjeta del recado apareció antes que «La compra … ya está en marcha» | El plugin arranca el recado antes de que el modelo conteste; la tarjeta esperaba la respuesta solo 15 s y un modelo que piensa tarda más | `ErrandTranscript.replyWait` 15 → 45 s |
| El navegador a veces se muestra y a veces no | Solo se mostraba con el recado `working`; desaparecía al pedir login, código o aprobación y volvía después | Se muestra desde el primer paso hasta que el recado termina |
| «Me pidió iniciar sesión dos veces después de crear la cuenta» | La segunda petición era el **código de verificación** que Prozis envía al crear la cuenta (`vault.code`); la tarjeta decía «Acceso a la tienda» en ambos casos, y «Ahora no» paraba la compra | La tarjeta distingue «Iniciar sesión en …» de «Código de verificación» con su texto y botones; «Ahora no» ya no para: sigue como invitado (plugin, A/C1) |

### Captura del 2 oct (02:55): texto que dice «toca su tarjeta» y ninguna tarjeta

| Causa | Cambio |
|---|---|
| Las tarjetas solo existían si el modelo llamaba a `purchase_options` con los argumentos correctos y la llamada acababa bien. Aquí verificó la cesta, escribió el texto y no hubo tarjeta que tocar. Además `purchase_options` fallaba entero por un `search_id` equivocado, un formato omitido o una recotización lenta. | El plugin enseña las tarjetas él mismo en cuanto termina la verificación (`purchase_prices.auto_present`, desde `purchase_verify`); el resultado de esa llamada lleva el `set` y la app lo pinta desde ahí (`PurchaseOptionSet.cardCalls`). La llamada del modelo solo añade su recomendación sobre las mismas tarjetas (`_adopt`, con alias de clave para la relectura del transcript). `search_id` erróneo, formatos omitidos y recotizaciones fallidas ya no impiden mostrar; lo no comprobado se dice. Tests: `test_the_cards_go_up_from_the_evidence_and_the_models_call_only_decorates_them`, `test_a_models_call_with_a_wrong_search_id_or_a_missing_format_still_shows_cards`, iOS `testTheCardsComeFromTheVerificationAndTheOptionsCallIsTheSameCards`. |
| El precio de las 80 cápsulas salió a 59,98 € (anoche 29,99 €) | No comprobable desde aquí (Prozis devuelve 429 al contenedor). El importe sale del elemento `.item-price-info .price` de la cesta; si Prozis muestra el precio sin descuento en otro nodo sin tachar, se lee ese. Pendiente: mirar `~/.alice/purchase-evidence.json` (campo `price` y `coupon_results` de la cotización de las 02:55). |

### Captura del 2 oct (03:35): otra vez texto sin tarjetas

Compatible con un modelo que contesta de memoria con las cotizaciones del turno anterior, sin
llamar a ninguna herramienta («Thought for a moment» y respuesta directa). Dos cambios que no
dependen del modelo: (1) la app pinta las tarjetas de cualquier conjunto que el plugin haya
mostrado durante la ventana del turno (`GET /purchase/sets`, `PurchaseTurnWindows`,
`PurchaseTurnSets`), haya o no llamada de herramienta en el transcript; (2) una petición
repetida de lo mismo vuelve a mostrar el conjunto anterior en ese turno sin buscar
(`purchase_flow.reshow`), y el modelo recibe solo la orden de recomendar. Tests:
`test_the_sets_of_a_turn_are_found_by_when_they_were_shown`,
`test_asking_again_shows_the_same_cards_again_instead_of_a_new_search`,
`test_asking_again_brings_the_cards_back_without_a_search`, iOS `testEachTurnHasOneWindowOnItsLastReply`.

**Confirmado con la rama instalada (56d05c3, app v7):** la captura de las 03:35 era con la rama. Causa
encontrada: `purchase_verify` devolvía `{"ok": true, "result": {…, "set": K}}` y la app leía `set`
solo en el nivel de arriba, así que las tarjetas desde la verificación no podían salir nunca.
Corregido por los dos lados (el plugin pone `set` también arriba; la app lo lee donde esté, y
acepta resultados que lleguen como texto JSON). Test: `test_the_verify_tool_names_the_cards_set_at_the_top_of_its_answer`,
iOS `testTheVerificationCallsSetIsReadWhereverTheToolPutIt`. Las tarjetas por ventana de turno (72c8c21)
son la segunda red, independiente de esto.

### Capturas del 2 oct (04:16), rama instalada: parada por «Prozis exige una fecha de nacimiento»

Primera prueba con tarjetas, elección, recado y tienda funcionando. Dos causas, las dos del plugin:
(1) un dato que la tienda pide y el agente no tiene se trataba como bloqueo final; ahora
`errands.missing_datum` lo convierte en una pregunta de la tarjeta del recado (fecha de nacimiento,
DNI, teléfono…), la respuesta se guarda en los datos de la persona (`birthdate` nuevo en
`ask_person.FIELDS` y en Ajustes) y el recado sigue. (2) El agente fue a «Crear cuenta» aunque la
bóveda ya tenía el acceso de Prozis de las 02:25; ahora `login_request` se rechaza cuando la bóveda
tiene un acceso de ese origen (salvo `replace=true` tras un `login_fill` fallido) y el brief lo dice.
Además la tarjeta del recado ya no repite el motivo de la parada que la tarjeta «Parada» muestra
debajo. Tests: `test_a_datum_the_shop_demands_is_asked_and_kept_not_a_stop`,
`test_a_login_the_vault_already_holds_is_used_not_asked_again`.

### Los 18 problemas históricos y qué test los sujeta

| # | Problema | Test |
|---|---|---|
| 1 | Creapure «no hay» y otra marca | `test_purchase_flow` · `test_requested_brand_is_kept_without_padding_with_another_brand`, `test_purchase_evidence` · `test_all_found_formats_must_be_accounted_for` |
| 2 | Sin navegador en la primera búsqueda | `test_errands` · `test_the_preamble_makes_and_then_keeps_one_context_and_tab`; visual, pendiente en iPhone |
| 3 | «La comprobación de Prozis falla» y ninguna opción | `test_purchase_evidence` · `test_a_format_the_service_could_not_check_does_not_lock_the_others`, `test_a_failed_check_names_its_selector`, `test_checking_the_remaining_formats_stops_within_the_tool_calls_time` |
| 4 | Texto recomienda uno y la etiqueta otro | `test_purchase_flow` · `test_the_reply_is_told_which_card_is_recommended` (depende del modelo: la etiqueta la pone el plugin, el texto no) |
| 5 | La tarea se paraba antes de tiempo | `test_errands` · `test_what_the_agent_can_fix_is_not_the_persons_to_hear`, `test_the_engine_warns_once_about_a_page_and_stops_the_second_round`, `test_moving_on_after_the_warning_is_not_going_round` |
| 6 | Sin navegador en un intento | `test_errands` · `test_no_gateway_leaves_it_stuck`; `Engine.run` → `prepare_browser` |
| 7 | Pidió login dos veces | `test_purchase_evidence` · `test_a_login_already_given_is_not_asked_again` |
| 8 | Tras pedir acceso, paró a los segundos | `test_errands` · `test_an_answer_given_while_the_run_still_goes_on_is_not_lost`, `test_purchase_evidence` · `test_secrets_only_go_to_vault_and_resume_same_errand_once` |
| 9 | Alerta que no se cerraba | `test_errands` · `test_an_alert_is_closed_before_the_step`, `test_a_confirm_that_orders_is_never_accepted` |
| 10 | Dos unidades en la cesta | `test_errands` · `test_extra_units_are_the_agents_to_fix_not_a_price` |
| 11 | Precio de tarjeta ≠ cesta | `test_purchase_evidence` · `test_a_lower_basket_price_goes_on_without_asking`, `test_real_price_change_exposes_both_amounts` |
| 12 | Sin «comprar igualmente» ni cancelar | `test_errands` · `test_a_new_price_is_the_persons_to_accept_and_the_errand_goes_on`, `test_purchase_evidence` · `test_a_stuck_purchase_can_be_cancelled`, `test_an_accepted_new_price_needs_no_second_cart_check` |
| 13 | «Reintentar» sin sentido | Mismos que 12; el reintento solo existe para paradas que no son de precio |
| 14–17 | Orden de tarjeta, mensaje y navegador en el chat | iOS `ErrandTranscriptTests`, `PurchaseFlowTests` · `testChosenPurchaseIsUnderTheUserTurnAndNeverAnotherSession`; visual, pendiente en iPhone |
| 18 | Compra completa con mínima intervención | `test_purchase_evidence` · `test_the_banks_payment_page_is_where_the_approved_order_is_paid`, `test_the_cart_check_survives_new_cookies_and_other_pages_but_not_another_context`; `scripts/verify-purchase-complete.py --agent`; **una compra real sigue pendiente** |

Alcance: `main` en ea068dc (PR #58). Leído entero el camino chat → recado → pago en
`hermes-plugin/` (`purchase_flow.py`, `purchase_prices.py`, `purchase_prozis.py`,
`errands.py`, `errand_access.py`, `purchases.py`, `vault_cards.py`, `money.py`, los hooks de
`__init__.py` y las rutas de `dashboard/plugin_api.py`) y en iOS (`Errand.swift`,
`PurchaseOptions.swift`, `PurchaseChoice.swift`, `ErrandBoard.swift`, `ErrandCards.swift`,
`PurchaseOptionsCard.swift`, `ErrandTranscript.swift`).

Qué es cada cosa:

- **Hecho**: se lee en el código y se puede reproducir con una llamada o un test.
- **Inferencia**: consecuencia del código sobre cómo se comportan las tiendas reales; no se ha
  ejecutado contra una tienda desde aquí.
- **Especulación**: depende del modelo o de una tienda concreta.

Objetivo que pides: que cualquier modelo complete la compra con la mínima interacción. La
conclusión general es que el flujo tiene **demasiadas puertas que dependen de que el estado del
navegador no cambie** (cookies, pestaña, origen, selectores) y de **que el modelo interprete bien
un mensaje de error**. Cada puerta añade un fallo nuevo en una tienda distinta. Eso es lo que
estás viendo.

---

## A. Lo que impide pagar (bloqueantes)

### A1. El pago en la página del banco (Redsys y similares) está bloqueado por construcción

**Hecho.** `hermes-plugin/__init__.py:407-411`: antes de rellenar la tarjeta o pulsar pagar, el
hook llama a `purchase_prices.payment_ready`. Esa función (`purchase_prices.py:499`) llama a
`checkout_amount` (`:486`), que exige que **la pestaña fijada del recado esté en el origen de la
tienda** (`page_origin != origin(offer.url)` → `ValueError`). Cuando la tienda redirige a
`sis.redsys.es`, `checkout.stripe.com`, etc., la pestaña está en el banco, la comprobación lanza
excepción, `_guard_errand` la captura (`:413-415`) y bloquea con «No se pudo comprobar la
aprobación del pago; no pagues». Y aunque no lanzara, `fresh_cart` (`:481`) ya devuelve `False`
porque exige `page_origin == evidence['origin']`, es decir, la tienda.

Consecuencia: en cualquier tienda que pague en pasarela externa (la mayoría de tiendas
españolas pequeñas: Piensos Raposo, etc.), la tarjeta nunca se rellena y «Pagar» nunca se
pulsa, aunque la persona haya aprobado. El agente recibe un bloqueo que no puede resolver, vuelve
a pedir `checkout_request`, la persona aprueba otra vez y se repite.

Introducido en cf04021 (30 sep). Las compras reales anteriores (README) son de antes de esta
puerta. El script `scripts/verify-purchase-complete.py` no lo detecta porque su tienda ficticia
paga en la misma página del resumen.

**Arreglo:** en `payment_ready`, si el origen actual es una pasarela conocida
(`vault_cards.PAYMENT_GATEWAYS`) o el host del banco al que la tienda redirigió, no releer el
selector del total en esa página: dar por válida la última lectura hecha en la tienda si es
reciente (p. ej. < 10 min) y el importe aprobado coincide. Alternativa más estricta: leer el
importe en la página del banco con un selector propio (Redsys muestra «Importe»), pero eso es
otro adaptador por banco.

### A2. La «sesión de cesta» se invalida con cualquier cookie nueva

**Hecho.** `purchase_check_cart` guarda un hash de **todas** las cookies del host (nombre, valor,
caducidad) en `cart_evidence.session` (`purchase_prices.py:32`, `:467`). `fresh_cart` (`:473`)
exige que ese hash sea idéntico; se consulta en `checkout_request` (`__init__.py:1835`) y en el
momento de pagar (`payment_ready`). El test
`test_same_price_after_session_change_needs_no_acceptance` confirma que cualquier cookie nueva
pone `fresh_cart` en `False`.

**Inferencia.** Entre la cesta y el pago el agente navega por login, dirección, envío y pago. Las
tiendas reescriben cookies en casi cada respuesta (sesión con caducidad deslizante, `__cf_bm`,
analítica, CSRF). Resultado práctico: `checkout_request` responde «Comprueba primero la cesta…
Cambió la sesión»; el agente vuelve a la cesta, repite `purchase_check_cart`, vuelve al pago, y
las cookies han cambiado otra vez. Y si por suerte llega a la aprobación, al pulsar pagar vuelve
a fallar con «El total o la sesión cambiaron». Es un bucle con la persona aprobando varias veces.

**Arreglo:** vincular la evidencia al **contexto del navegador** (ya se comprueba) y, como mucho, a
la cookie de sesión de la tienda (la que no cambia), no al conjunto completo. O eliminar el hash y
confiar en que el importe final se relee del resumen (que ya se hace en `checkout_amount`).

### A3. La evidencia de la cesta caduca a los 15 min contados desde `purchase_check_cart`

**Hecho.** `TTL = 15 * 60` (`purchase_prices.py:28`) se aplica en `fresh_cart` sobre
`cart_evidence.at`. Ese reloj arranca al comprobar la cesta, no al pedir la aprobación. Si entre
la comprobación y el clic de pagar pasan más de 15 min (login + OTP + que la persona vea la
tarjeta de aprobación + 3DS), el pago se bloquea con «El total o la sesión cambiaron» después de
que la persona ya aprobó. Sumado a `APPROVAL_TTL` (10 min, `errands.py:43`) y
`CHECKOUT_TTL` (15 min, `:46`), hay tres relojes distintos que pueden expirar en un mismo intento.

**Arreglo:** un solo reloj: la aprobación. Al aprobar, refrescar `cart_evidence.at` (o medir la
frescura de la cesta desde `checkout.decided_at`).

### A4. Checkouts de una sola página se matan como «dando vueltas»

**Hecho.** `circling` (`errands.py:1087`) marca el recado como atascado cuando los últimos 12
pasos están en la misma ruta (`page_of` quita la query y el fragmento) durante más de 4 min.
Prozis hace cesta, dirección, envío y pago en `/es/es/checkout/index`; Shopify y Magento también
usan una ruta única. Doce pasos con comentario en 4 min es lo normal en un checkout largo.

Consecuencia: «Lleva varios minutos en la misma página sin poder avanzar» justo cuando estaba
avanzando.

**Arreglo:** contar «vueltas» solo si además no hay cambio en el DOM (p. ej. el hash del texto de
la página) o si el mismo texto de paso se repite; o subir el umbral y excluir rutas con `checkout`.

### A5. El mensaje de aprobación (y «tarjeta lista», respuestas, reintentos) se pierde si el modelo todavía no terminó su turno

**Hecho.** `resume` (`errands.py:1502`) pone `status=working` y llama a `launch`. `launch`
(`:1410`) toma un lock por recado y, si otro motor lo tiene, **devuelve `False` y descarta el
mensaje**. El motor lo tiene mientras la ejecución del modelo siga viva: `checkout_request` deja
el recado en `needs_approval`, pero el run no acaba hasta que el modelo termina su turno. Si la
persona aprueba en esos segundos, el «[checkout aprobado]» nunca llega; el motor sigue con la
continuación del juez, el agente no sabe que se aprobó y vuelve a llamar a `checkout_request`
→ segunda aprobación.

El login no sufre esto porque `errand_access.answer` guarda `resume_message` en el recado antes
de llamar a `resume` (`errand_access.py:226`); los demás caminos no.

**Arreglo:** que `resume` guarde siempre `resume_message=message` en la entrada (el bucle de
`Engine.run` ya lo consume en `:1281-1283`), y que `launch` lo use.

### A6. Elegir «con palabras» no funciona, aunque la skill y la descripción de la herramienta lo prometan

**Hecho.** `errand_start` con `option_id` exige `chosen_set['chosen'] == option_id`
(`__init__.py:1813-1816`); `chosen` solo lo fija la pulsación de la tarjeta vía `_errand_turn`.
Si la persona escribe «la segunda» y el modelo llama a `errand_start`, obtiene `NEEDS_CHOICE` y
vuelve a enseñar las tarjetas. `docs/purchases.md` paso 6, `OPTIONS_SCHEMA` y `SKILL.md` dicen
que se puede decir con palabras.

**Arreglo:** o bien permitir que `errand_start` con `option_id` de un set enseñado en esa sesión
elija (y marcar `chosen`), o bien quitar la frase de la skill, de la descripción y de los docs.

---

## B. Lo que hace que la compra «de cualquier cosa» no sea alcanzable hoy

### B1. El catálogo Shop no puede llegar a tarjetas: toda opción necesita `quote_ref` de `purchase_verify`

**Hecho.** `purchase_prices.present` (`:381`) resuelve cada opción con `resolve(quote_ref)` y
exige `search_id` con cobertura; una opción de `catalog_search` no tiene ni lo uno ni lo otro y
la llamada entera falla. `OPTIONS_SCHEMA` requiere `quote_ref`. Sin embargo `SKILL.md` paso 2,
`turn_note`, `docs/purchases.md` paso 3 y el README siguen diciendo «busca en catálogo y tienda».
El modelo gasta turnos en el catálogo y acaba con errores.

**Arreglo:** decidir. O el catálogo es solo descubrimiento (quitarlo de las instrucciones de
compra y dejarlo para «¿dónde lo venden?») o se le da un camino de verificación.

### B2. Fuera de Prozis, verificar exige que el modelo adivine selectores CSS de ficha y cesta

**Hecho.** `purchase_verify` sin adaptador necesita `title`, `add`, `line`, `price`,
`cart_quantity` observados; la línea de cesta debe contener literalmente el título de la ficha
**y** el título del listado (`variant = candidate['title']` cuando no hay selector de variante,
`purchase_prices.py:276`). Un `KeyError` (p. ej. cupones sin `coupon` en la receta, `:314`)
sale como «La comprobación de la cesta temporal no está disponible», sin pista.

**Inferencia.** Los títulos de listado y de cesta rara vez coinciden carácter a carácter («500g»
vs «500 g», mayúsculas, truncados). La primera receta falla, se anota como «no comprobable» tras
un reintento, y la compra muere en el paso 4. Es la razón por la que solo Prozis funciona.

**Arreglo mínimo:** comparar por palabras clave normalizadas (sin acentos, espacios, unidades),
no por inclusión literal; relajar `variant` cuando no hay selector; errores con el selector que
falló. Arreglo real: una receta genérica (heurísticas de `add to cart`, línea de cesta, precio)
como la de Prozis pero sin selectores fijos.

### B3. El filtro de «identidad» de la petición descarta opciones válidas en silencio

**Hecho** (`purchase_flow.requested_identity`, `:125`, probado):

| Petición | Identidad detectada | Efecto |
|---|---|---|
| «Cómprame una botella de agua de 1 litro» | `1 litro` | se descartan las fichas que digan «1 L» |
| «Quiero comprar la creatina de HSN de 500 g» | `500 g` | HSN deja de ser la marca; «500g» se descarta |
| «compra pilas AA en Amazon» | `amazon` (solo tienda) | correcto |

Cuando no queda nada, el error dice «No hay opciones válidas de 1 litro; no ofrezcas otra marca».

**Arreglo:** solo aceptar como identidad palabras que aparezcan en el merchant/host de alguna
opción o que precedan a «marca/brand»; nunca cantidades ni unidades.

### B4. «Pídeme cita», «order a taxi» se tratan como compras y no pueden empezar

**Hecho.** `PURCHASE_REQUEST` (`purchase_flow.py:37`) incluye `pide|pedir|order`.
`is_purchase_request("Pídeme cita en el dentista")` es `True`, y `errand_start` con ese `task`
devuelve `NEEDS_CHOICE` (`__init__.py:1820`). Un recado no-compra con esas palabras nunca arranca.

**Arreglo:** exigir además un objeto comprable o quitar `pide/pedir/order` del patrón y dejar
`comprar/carrito/cesta/buy/purchase`.

### B5. La búsqueda Prozis se construye con la palabra «cómprame» dentro

**Hecho** (probado): `FILLER` (`purchase_prozis.py:18`) no contempla acentos; con «cómprame
creatina creapure de prozis» la URL es `search?text=cómprame creatina creapure` y las keywords
incluyen `cómpra`. Prozis probablemente devuelve cero resultados y el modelo recibe «No se
encontraron formatos».

**Arreglo:** normalizar acentos antes de aplicar `FILLER` (hay `_normalized` en `purchase_flow`).

### B6. `import time`/`json`/`re` en `browser_exec` está prohibido dentro de un recado

**Hecho.** `_isolate_errand_browser` (`__init__.py:289-296`) bloquea cualquier `import`.
**Especulación:** los modelos escriben `import time; time.sleep(2)` constantemente; cada bloqueo es
un paso perdido y alimenta el contador de «vueltas» (A4) y el guard de repetición.

**Arreglo:** permitir `time`, `json`, `re`, `math`; seguir bloqueando red, ficheros y `cdp`.

---

## C. Puertas que piden interacción extra a la persona

### C1. `detect_pending` convierte cualquier campo de contraseña vacío en «Acceso a la tienda»

**Hecho.** Tras cada run, `Engine.run` llama a `detect_pending` (`errand_access.py:232`), que
pide login si hay un campo `current-password` u OTP vacío en la página fijada. **Inferencia:** los
checkouts como invitado suelen mostrar un login opcional («¿Ya tienes cuenta?»). El recado se para
en `needs_login` y la persona tiene que meter credenciales o pulsar «Ahora no» (que **detiene** el
recado: `answer` con valor vacío → `stopped`, `:172`). Choca con «prefiere compra como invitado».

**Arreglo:** solo auto-detectar cuando el formulario ocupa la página (sin botón de invitado
visible) o cuando el propio agente intentó `login_fill`; «Ahora no» debería continuar como
invitado, no parar.

### C2. La respuesta de login falla si la pestaña cambió mientras el modelo acababa su turno

**Hecho.** `answer` exige mismo origen, contexto y target que la solicitud
(`errand_access.py:176`). `login_request` se registra, pero el modelo puede seguir navegando en
ese turno (recargar, abrir otra pestaña). La persona rellena la hoja y recibe «No se pudo guardar
el acceso. Comprueba la solicitud y reintenta» (409) sin saber por qué.

**Arreglo:** si la página cambió pero el origen es el mismo, aceptar y volver a inspeccionar.

### C3. La tarjeta que la persona elige al aprobar no se impone al rellenar

**Hecho.** `decide_checkout` guarda `card_label` (`errands.py:462`); `_guard_errand` no compara
`meta.label` del `browser_vault_fill` con ese label. Si hay dos tarjetas, el modelo puede
rellenar la otra. **Especulación** sobre frecuencia; coste alto si pasa.

**Arreglo:** en el gate de fill, bloquear si `identity(meta.label) != identity(checkout.card_label)`.

### C4. La elección de un formato puede tardar un minuto y, si falla, dice «vuelve a tocar»

**Hecho.** `_errand_turn` → `_start_purchase` → `resolve` (`__init__.py:1598`) revalida en un
contexto desechable si cambian las unidades o la cotización tiene >15 min. Ocurre dentro del hook
`pre_llm_call`, bloqueando el turno. Si falla (tienda lenta, navegador caído) la persona recibe
«No he podido iniciar la compra… que vuelva a tocar la opción» y al tocar pasa lo mismo.

**Arreglo:** si la revalidación falla, arrancar igualmente el recado (que ya tiene
`purchase_check_cart` para confirmar el precio) y decirlo en una línea.

### C5. Tras aceptar un precio nuevo, el agente no sabe que debe volver a `purchase_check_cart`

**Hecho.** `check_cart` deja el recado `stuck` sin escribir `cart_evidence`
(`purchase_prices.py:463-465`). `go_on(accept_price)` manda «Sigue con el carrito hasta el paso
de pago y llama a checkout_request» (`errands.py:805`), pero `checkout_request` exige
`fresh_cart` → error «Comprueba primero la cesta». Un modelo débil se queda ahí.

**Arreglo:** en `[precio aceptado]` decir explícitamente «llama a purchase_check_cart y después a
checkout_request», o escribir la evidencia al aceptar.

### C6. Antes de aprobar, el agente no puede tocar nada en una URL con `/payment` o `/pago`

**Hecho.** `is_pay_action` (`errands.py:526`) devuelve `True` para **cualquier** clic si la URL
activa casa con `PAY_PAGE`; probado: elegir el radio «Tarjeta de crédito» en
`/checkout/payment` se bloquea. En tiendas donde el total final solo aparece tras elegir método,
`checkout_request` se pide con un total que luego cambia (o no se puede pedir).

**Arreglo:** antes de la aprobación, permitir clics que no sean el botón de pagar en la página de
pago, y bloquear solo `PAY_WORDS` y el envío del formulario de tarjeta.

### C7. Tres caducidades distintas obligan a «Prepararlo de nuevo»

Ver A3. `CHECKOUT_TTL` 15 min: una aprobación que llega con el teléfono bloqueado 20 min aparece
como «Caducado» y hay que preparar otra vez (la tienda vuelve a navegar, A2 y A4 vuelven a actuar).
El README promete lo contrario («An approval sent while the phone was locked comes back into the
chat when you open it»).

---

## D. Errores de app (iOS)

### D1. Opciones 7 en adelante rompen la fila de elección

**Hecho.** `PurchaseChoice.swift:5` acepta solo `-[1-6]`; el plugin genera `-[1-9][0-9]*` y
pagina de seis en seis (`PurchaseOptionsCard`, páginas 2+). Al tocar la opción 7, el mensaje del
usuario muestra el token crudo `[elección:xxxxxxxx-7] …` y `ErrandTranscript` no coloca el
recado bajo la elección (usa `PurchaseChoice.id`).

**Arreglo:** `-[1-9][0-9]*` en Swift, y un test en `PurchaseOptionsKeyTests`.

### D2. El marcador `[cantidad:N]` queda visible en la burbuja

**Hecho.** `PurchaseOptionsCard.swift:76` envía `… [cantidad:2]`; `PurchaseChoice.display` solo
quita el prefijo de elección. Cosmético.

### D3. Tarjeta nueva desde un recado siempre al perfil `default`

**Hecho.** `ErrandStack` crea `PaymentCardOffer(origin:…, profile: "default")`
(`ErrandBoard.swift:227`) ignorando `errand.profile`. Solo afecta a recados de otros perfiles.

---

## E. Deuda que no rompe hoy pero volverá

- **`purchase_outcome: declined/unknown` no cierra el recado.** `Engine.run` solo termina con
  `paid`; con `declined` sigue al juez, que empuja a «completar» hasta `stuck`. La ficha muestra
  recibo y «Se ha atascado» a la vez. Debería terminar en `done` con el recibo.
- **`condition` de Prozis** se fija siempre que haya un `input[type=email]` visible en la cesta
  (`purchase_prices.py:334`), aunque no haya descuento anunciado: la tarjeta avisa de un descuento
  que no existe.
- **`verify_remaining`** comprueba todos los formatos en serie dentro de una sola llamada de
  herramienta (`:510`): con 8 formatos y cupones son minutos; riesgo de timeout de la herramienta
  y de que el modelo repita la llamada.
- **`known_prices`** (precios corregidos por una cesta anterior) nunca llega a
  `purchase_flow.present` desde `purchase_prices.present`: código muerto.
- **Pulsar dos veces la misma opción con precio cambiado** crea dos recados `stuck`
  (`_start_purchase` rama `price_changed` no deduplica).
- **`Probe.goto` rechaza redirecciones de host** («La tienda redirigió a otro origen»): una tienda
  que redirige `tienda.com` → `www.tienda.com` no se puede verificar.
- **Tests del plugin aquí**: 506 tests, 2 fallos y 19 errores, todos por falta del runtime de
  Hermes (`agent`, `hermes_cli`, `hermes_constants`), no por lógica. No he podido ejecutar nada
  contra una tienda ni contra el gateway.

---

## Recomendación

Hay dos familias de causa, y hay que elegir orden:

1. **Puertas del pago (A1–A5).** Sin esto no se paga ni en Prozis ni en Redsys, con cualquier
   modelo. Son cinco cambios pequeños en `purchase_prices.py` y `errands.py`, con tests de
   fixtures ya existentes que se pueden extender (`test_purchase_evidence.py`,
   `test_errands.py`).
2. **Alcance «cualquier cosa» (B1–B2).** Es trabajo de diseño: hoy solo Prozis tiene camino
   completo. Lo honesto es decirlo en el README y en la skill hasta que exista una receta genérica.

Orden propuesto: A1, A2, A3, A5 en una sola PR (una tarde); A4 y C6 en otra; después decidir B1.

## Acción de menos de 30 minutos

Reproducir A1 con el fixture sin tocar tiendas: en
`hermes-plugin/tests/test_purchase_evidence.py`, copiar
`test_payment_requires_the_exact_approved_visible_total` y cambiar `self.inspect` para que
devuelva `('https://sis.redsys.es', …)`. El test debe fallar hoy (`payment_ready` lanza o devuelve
`False`). Ese test rojo es el punto de partida de la PR 1.

```bash
PYTHONPATH=$HOME/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python \
  -m unittest discover -s hermes-plugin/tests -p test_purchase_evidence.py -k payment
```
