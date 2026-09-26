# Conectar Alice con tu Hermes

Alice necesita que tu Hermes esté instalado, configurado y encendido. Una
suscripción o cuenta de Nous Portal por sí sola no proporciona una dirección
de conexión a un Hermes instalado en tu ordenador.

## En iPhone: conexión manual

1. Abre **Connect** en Alice.
2. Introduce la dirección del servicio Hermes y su clave de acceso.
3. Pulsa **Connect**.

Obtén ambos datos de quien haya instalado Hermes. No utilices la clave de tu
proveedor de modelos: es otra credencial. Para un servidor público usa HTTPS.

Si Hermes está en una red privada, el iPhone debe poder alcanzarla. Tras
conectar, Alice muestra qué partes están disponibles: el chat puede funcionar
aunque Agents, Projects, Memory y Usage aún necesiten el panel.

## Atajo: emparejar con un QR

Si el complemento Alice está en el panel de Hermes:

1. Conecta el iPhone y el ordenador a la misma red (en muchos Mac, Tailscale).
2. En el panel, pestaña **Alice** → **Show pairing code**.
3. En Alice, **Scan pairing QR**.
4. Confirma. Si Alice indica que solo ha conectado una parte, reintenta el
   panel desde Advanced en esa misma pantalla.

El ordenador debe seguir encendido y accesible.

## Crear un agente sin mezclar encargos

En **Agents → Add → New Agent**, Alice abre una conversación nueva con Forge
(si está disponible). Escribe lo que necesitas y envíalo. El chat principal de
Forge conserva su historial y sus borradores. Cada encargo aparece en **Recents**
y se puede volver a abrir desde el botón de chats. El panel Hermes debe estar
conectado. Si una sesión guardada ha desaparecido del servidor, Alice muestra el
error en lugar de repetir el encargo en otra conversación.

## Trabajo de los agentes

Con el complemento Alice y el panel conectados, abre **Settings → Agent work**
en el iPhone:

- **Page watches:** activa la vigilancia la primera vez y añade una página.
  En el Mac se instala `changedetection.io` en un entorno separado. Elige si
  quieres saber de una bajada de precio, una reposición, un texto o cualquier
  cambio. Puedes detener cada vigilancia desde su fila.
- **Shared browser:** inicia un navegador Chromium compartido en el Mac.
  Podrás ver su página, tocarla, escribir y desplazarte desde el iPhone. Al
  apagarlo, Alice restaura la configuración anterior de los agentes.
- **Documents:** elige un PDF o CSV. Alice lo copia al Mac y muestra la ruta
  que puedes pegar en el chat para pedir que lo lea o lo complete. Revisa
  siempre el PDF resultante antes de firmarlo o enviarlo.

Estas funciones necesitan el panel además del servicio de chat. La vigilancia
se instala solo cuando la activas; requiere que el Mac esté encendido y tenga
acceso a las páginas vigiladas. El navegador compartido requiere Chrome u otro
navegador Chromium instalado en el Mac.

### Instalar el complemento (un comando)

Desde una copia de este repositorio, en la máquina que ejecuta Hermes:

```bash
hermes-plugin/install.sh
```

Copia el complemento, lo activa y, en macOS, reinicia el panel si el servicio
está instalado. Reinicia también cualquier gateway en marcha: Hermes carga los
plugins una vez por proceso.

### No aparece la pestaña Alice

El complemento aún no está instalado, o el panel no se ha reiniciado. En Linux,
Windows o un servidor sin el plugin, usa la conexión manual; el QR no es un
instalador universal de Hermes.

### El código ha caducado o ya se ha utilizado

Genera otro en el panel. Durán cinco minutos y solo se pueden canjear una vez.
No compartas el QR: permite obtener acceso a tu agente.

### Alice no encuentra Hermes

Comprueba que ambos dispositivos tienen red, que Tailscale (si lo usas) está
conectado y que Hermes está encendido. Si acabas de cambiar de red, espera a
que termine de conectar.

## En la web

Abre **Connect**, introduce la dirección y la clave. En el modo directo, Hermes
también debe permitir el origen de Alice mediante CORS. La pantalla incluye el
diagnóstico correspondiente.

## Comentarios entre herramientas

Hermes puede emitir `message.interim` cuando
`display.interim_assistant_messages` es `true` en su `config.yaml`. Alice
también guarda lo que el modelo ya escribió al empezar una herramienta, así
que la narración se ve aunque esa opción esté apagada.

## Funciones que no aparecen o no están disponibles

El chat y las funciones de administración pueden usar servicios diferentes de
Hermes. Conectar solo el servicio de chat no garantiza acceso al panel, sus
agentes o su configuración. Alice muestra esa distinción después de conectar.
Una función no comprobada no equivale a una función compatible.
