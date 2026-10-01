---
name: comprar
description: Compra con elección explícita, precios comprobados y aprobación del total.
---

## Comprar

En el chat buscas y muestras opciones; solo el servicio de comprobación toca una cesta temporal aislada. Nunca llenes la cesta personal desde el chat.

1. Aclara solo lo que sabe la persona y cambia la búsqueda. País y moneda vienen del contexto, no los preguntes. Una marca no elige formato. No preguntes cantidad antes de elegir: en el detalle hay unidades, inicialmente 1. Nunca inventes talla, compatibilidad, dirección ni presupuesto.
2. Busca en catálogo y tienda real. Una portada o la ficha de MicronPure no demuestra que Prozis no venda Creapure: revisa la categoría completa. Registra TODOS los formatos encontrados con `purchase_discover`: página y selector de enlaces de producto. No omitas tamaños ni formatos ni sustituyas el producto o marca pedidos. No presentes sustituciones mediante `ask_person` cuando una búsqueda o verificación haya fallado.
3. Para cada candidato, `purchase_verify` con los selectores de ficha y cesta. En Prozis omite `recipe`: el servicio usa los controles observados, selecciona la variante mostrada, maneja el contador de unidades y prueba los códigos públicos de la ficha. Devuelve también los otros formatos comprobados; inclúyelos todos. Comprueba stock, variante, cantidad y precio de una cesta desechable, sin login ni pago; o descártalo con falta de stock comprobada. Un fallo técnico no es falta de disponibilidad. Un precio tachado o anunciado no es el precio comprable. Código de descuento: busca y prueba descuentos públicos sin crear cuenta ni suscribirte. Si exige login, explícalo como condición pendiente y muestra el importe realmente aplicado; separa producto y envío.
4. `purchase_options` con `search_id` y `quote_ref` de cada opción: el importe lo toma el plugin del registro comprobado, no de lo que escribas. Presenta todos los formatos válidos; se paginan en grupos de seis. Una tarjeta basta solo para un producto exacto o una única opción comprable encontrada. Marca una recomendación y explica por qué en una o dos líneas; termina el turno sin preparar nada.
5. Espera la elección explícita. El iPhone transmite formato y unidades. No llames a `errand_start` para elegir por la persona. Si una oferta caducó, cambió la cantidad o cambió la sesión de la tienda, revalida antes de preparar; el mismo importe nunca exige aceptarlo otra vez.

En el recado preparas exactamente lo elegido: variante, cantidad, envío estándar y datos guardados. No añadas extras ni sustituciones. Una cesta del recado no copia ni borra la personal.

Si falta acceso de ESTE origen, `login_request`: se pide de forma segura en el iPhone y el mismo recado continúa. Usa `login_fill` solo con un acceso del origen exacto; no pruebes credenciales de otras tiendas. Para OTP, `login_request` con kind `vault.code`. Termina el turno mientras espera. No pidas secretos por chat ni remitas a Desktop. Crear cuenta requiere que la persona lo elija antes de pedir datos de registro; prefiere compra como invitado si existe.

Tras añadir el formato y después del login, `purchase_check_cart` comprueba precio y unidades de la cesta del recado. Antes de rellenar tarjeta o pagar, `checkout_request` con `total_selector` del importe final visible, los artículos, unidades, envío, impuestos/comisiones, dirección, tarjeta y total EXACTO del paso final. Si falta tarjeta, `card_request`. La persona aprueba ese total con «Permitir»; la confirmación de Hermes no equivale a aprobar la compra. Paga solo si el importe sigue coincidiendo, o pide una nueva aprobación por el cambio real.

Justo antes de pagar comprueba que no existe un pedido igual. Después de pulsar pagar, `purchase_outcome` con pedido, total y entrega. Un clic o cargo pendiente no prueba un pedido; un error posterior es `unknown`: comprueba confirmación/correo/pedidos y nunca pagues otra vez hasta resolverlo. Nunca afirmes que no se cobró sin comprobarlo.
