---
name: comprar
description: Cómo compra Alice online, en 12 pasos — aclarar, contexto, buscar en el catálogo y la tienda, verificar, opciones, elegir, preparar, método de pago, resumen, aprobación, pago y resultado.
---

<!--
Fuente única de las reglas de compra (docs/purchases.md). El plugin de Alice inyecta este archivo
(desde "## Comprar") en cada conversación; también se puede abrir como la skill `alice:comprar`. Lo
que no puede depender del modelo lo impone el código: sin opción elegida no hay recado
(purchase_flow.py), en el chat no se llena un carrito, sin checkout aprobado no se paga, y no se paga
dos veces (errands.py, purchases.py). Límite: 4000 caracteres a partir de "## Comprar".
-->

## Comprar

En el chat (sin tocar carrito ni pago):

1. **Aclara** qué quiere exactamente. Nunca ofrezcas una opción que no hayas visto: si lo que falta depende de lo que vende la tienda (formato, talla, sabor), mira primero la tienda y el catálogo y enseña lo que hay como tarjetas (paso 5). Lo que solo sabe la persona y no depende de la tienda (cantidad, para quién), pregúntalo en una línea. Nunca inventes talla, compatibilidad, dirección ni presupuesto.
2. **Contexto**: país, moneda, envío, tiendas y tarjeta de antes te los da Alice. **País y moneda no se preguntan nunca.**
3. **Busca** en el catálogo (`catalog_search`, `catalog_product` para la variante) **y** en la tienda real (web y su página), a la vez.
4. **Verifica**: página real del producto, en stock, precio en su moneda. Lo que no cumpla, fuera; los comparadores son pistas.
5. **Opciones**: `purchase_options` con 1–6 verificadas (también si es una sola; productos con precio nunca van en `ask_person`), la recomendada marcada y por qué, y termina tu turno con tu recomendación en una o dos líneas. No escribas las opciones como texto.
6. Elige tocando una tarjeta o con palabras; entonces `errand_start` con su `option_id`. Sin elección no hay compra.

En el recado (Alice lo enseña; tú solo lo preparas): 7. **Prepara** esa opción y nada más: carrito, envío estándar, sus datos. Si ya no está, cambia de precio o de variante, para y di qué cambió. 8. **Método de pago**: Alice comprueba que hay tarjeta guardada antes del total; si no, se la pide.
9–10. **Resumen y aprobación**: en el paso de pago, `checkout_request` con lo que muestra la página (artículos con variante y cantidad, envío, dirección, email, tarjeta y **total exacto**). La persona ve el desglose y aprueba ese total con «Permitir». Sin eso no hay pago, nunca; la confirmación de Hermes no es un sí. 11. **Paga** solo si la página muestra exactamente el total aprobado; si es otro, no pagues y pide aprobación otra vez. 12. **Resultado**: `purchase_outcome` con número de pedido, total, artículos, tarjeta y entrega prevista. Un cargo pendiente o un clic no es un pedido.

Si en cualquier paso falta un dato o algo falla (sin stock, sin tarjeta, sin precio en su moneda), para ahí, dilo en una línea y propone cómo seguir.

- **Total real:** producto + envío + comisiones + impuestos o aduanas + cambio de moneda.
- **Código de descuento:** en el checkout, si hay campo de cupón, busca «<tienda> código descuento» y en la propia tienda; prueba hasta 5 y quédate con el que más baje el total. No crees cuentas ni te suscribas por un descuento. Di qué código ahorró cuánto.
- **Carrito limpio:** no borres lo que ya tenía; quita extras marcados de serie (seguro, garantía, donación, suscripción, financiación).
- **Un solo pago:** justo antes de pagar, mira que no haya ya un pedido igual. Rellenar la tarjeta no es pagar: si la página del banco sigue con «Pagar» y el importe, púlsalo. Tras pulsar, llama siempre a `purchase_outcome`. Un corte o error después de pagar es «unknown»: compruébalo (confirmación, correo, «Mis pedidos») y nunca pagues otra vez mientras no se sepa. Nunca digas «no se ha cobrado» sin verlo.
