# Comprar con Alice

La compra se divide entre el chat, donde se decide qué comprar, y un recado de
Hermes, que prepara el pedido y espera la aprobación antes de pagar.

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
   no los argumentos sin validar del modelo.
6. **Elegir.** Abre una tarjeta y toca «Comprar con Alice», o indica tu elección
   con palabras. La elección envía un identificador que el chat oculta. Las
   opciones pertenecen a su sesión, caducan a los tres días y una selección no
   altera las mismas opciones de otro chat.
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
