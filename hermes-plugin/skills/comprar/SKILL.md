---
name: comprar
description: Cómo compra Alice online — elegir, total real, mejor código de descuento, carrito limpio, un solo pago y cierre con número de pedido.
---

<!--
Fuente única de las reglas de compra. El plugin de Alice inyecta este archivo (desde "## Comprar")
en cada conversación, así que siempre está presente; también se puede abrir como la skill
`alice:comprar`. Lo que no puede depender del modelo — no pagar dos veces — lo impone el código
en purchases.py. Límite: 4000 caracteres a partir de "## Comprar".
-->

## Comprar

«Busca», «recomienda» o «prepara el carrito» es preparar, sin pagar. «Cómpralo» o «compra X hasta Y €» es la autorización: no pidas otro sí (Hermes ya pregunta al rellenar la tarjeta). Nunca inventes talla, compatibilidad, dirección ni presupuesto; si falta algo que cambia la compra, junta las dudas en un solo mensaje con tu propuesta.

- **Elegir:** para un artículo exacto, comprueba modelo, variante, cantidad y estado; no lo cambies por uno parecido sin permiso. Para elegir, mira hasta tres opciones buenas y para cuando una cumple: no persigas céntimos. Precio, stock y entrega, en la tienda y para la dirección real; los comparadores son pistas.
- **Total real:** producto + envío + comisiones + impuestos o aduanas + cambio de moneda. Si algo del total no se sabe o supera el límite, no pagues.
- **Código de descuento:** antes de pagar, si la tienda tiene campo de cupón, busca en la web «<tienda> código descuento» y en la propia tienda (banner, página de ofertas). Prueba en el checkout hasta 5 códigos, de los más recientes a los más viejos, y quédate con el que más baje el **total**; si ninguno funciona, sigue sin él. Solo cuenta lo que el checkout aplica. No crees cuentas, no te suscribas a boletines, no instales extensiones y no salgas a webs de pago raras por un descuento. Di en una línea qué código ahorró cuánto.
- **Carrito limpio:** no borres lo que la persona ya tenía; quita extras marcados de serie (seguro, garantía ampliada, donación, suscripción, prueba que se renueva, financiación).
- **Un solo pago:** justo antes de pagar, vuelve a mirar producto, cantidad, dirección, total y que no haya ya un pedido igual. Rellenar la tarjeta no es pagar: si la página del banco sigue mostrando el formulario con «Pagar» y el importe, el pago no se ha enviado — pulsa «Pagar» (o vuelve a rellenar si algún campo quedó vacío); no es un segundo pago ni un «unknown». Después de pulsar «Pagar» llama siempre a `purchase_outcome` con cómo acabó. Un corte, un error o una página cerrada después de pagar es «unknown»: compruébalo (confirmación, correo, «Mis pedidos») antes de hacer nada más, y nunca pagues otra vez ni cambies de tienda mientras no se sepa. Nunca digas «no se ha cobrado» sin verlo.
- **Cierre:** «Pedido confirmado: qué, total, tienda, entrega prevista, número de pedido». Un cargo pendiente o un clic no es un pedido confirmado.
