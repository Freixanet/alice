# Conectar Alice con tu Hermes

Alice necesita que tu Hermes esté instalado, configurado y encendido. Una
suscripción o cuenta de Nous Portal por sí sola no proporciona una dirección
de conexión a un Hermes instalado en tu ordenador.

## En iPhone: conectar con un QR

1. Conecta el iPhone y el Mac a tu misma red de Tailscale.
2. Abre el panel de Hermes en el Mac y entra en la pestaña **Alice**.
3. Pulsa **Show pairing code**.
4. En Alice, abre **Connect → Scan pairing QR** y escanea el código.
5. Confirma la conexión. Si Alice indica que solo ha conectado una parte,
   reintenta la conexión al panel desde esa misma pantalla.

El Mac debe seguir encendido y accesible para poder usar su agente.

### No aparece la pestaña Alice

La pestaña la añade el complemento incluido en este repositorio. Una persona
que administre tu instalación debe seguir las [instrucciones de instalación](../hermes-plugin/README.md).
La preparación automática actual del QR está diseñada para macOS y Tailscale.
En otros entornos utiliza los datos de conexión manuales del administrador;
el QR todavía no constituye un instalador universal de Hermes.

### El código ha caducado o ya se ha utilizado

Genera otro código en el panel. Los códigos duran cinco minutos y solo se
pueden canjear una vez. No compartas el QR: permite obtener acceso a tu agente.

### Alice no encuentra Hermes

Comprueba que ambos dispositivos tienen conexión, que Tailscale está conectado
a la misma red y que Hermes está encendido. Si acabas de cambiar de red,
reintenta después de que Tailscale termine de conectar.

## En la web o con conexión manual

Abre **Connect**, introduce la dirección del servicio Hermes y su clave de
acceso. Obtén ambos datos de quien haya instalado Hermes. No utilices la clave
de tu proveedor de modelos como clave del servicio Hermes: son credenciales
distintas. Para un servidor público utiliza una dirección HTTPS.

Si Hermes está en una red privada, el dispositivo que lo contacte debe poder
acceder a esa red. En el modo directo de la web, Hermes también debe permitir
el origen de Alice mediante su configuración CORS. La pantalla de conexión
incluye el diagnóstico correspondiente.

## Funciones que no aparecen o no están disponibles

El chat y las funciones de administración pueden usar servicios diferentes de
Hermes. Conectar solo el servicio de chat no garantiza acceso al panel, sus
agentes o su configuración. Comprueba el estado de ambas conexiones en los
ajustes. Alice debe mostrar la disponibilidad detectada; una función no
comprobada no equivale a una función compatible.
