# Emparejamiento Alice ↔ Hermes (v1)

Configurar Alice a mano exige entender direcciones, puertos y claves. El
emparejamiento por QR lo sustituye por: **Hermes muestra un QR en el Mac →
Alice lo escanea → configurada**.

Implementación actual:

- **Lado Mac**: `npm run pair` (helper de este repo, `scripts/pair.mjs`). Lee la
  configuración de Hermes en modo solo lectura, emite un QR de un solo uso y
  sirve el canje hasta que se usa o caduca. No modifica `hermes-agent`.
- **Lado iPhone**: app nativa (`ios/Alice/Features/Connect/Pairing/`), con deep
  link `alice://` y escáner propio.

Este documento es el contrato para portar el lado Mac al dashboard de Hermes
más adelante. Quien lo implemente debe conservar la forma y las garantías de
v1 para que el cliente iOS no cambie.

## 1. El QR contiene una credencial de emparejamiento

```text
alice://pair?v=1&p=<base64url(json)>&s=<64 hex>
```

`p` es el JSON de la oferta, en base64url **sin padding** (RFC 4648 §5), con
las claves en este orden al emitirlo:

| clave | contenido                                                 |
| ----- | --------------------------------------------------------- |
| `c`   | URL absoluta del canje (`http://<ip-tailnet>:8643/claim`) |
| `t`   | token de un solo uso, aleatorio y opaco                   |
| `e`   | expiración, época Unix en **segundos enteros**            |
| `pr`  | nombre del perfil Hermes (opcional, solo informativo)     |

`v` vale `1`. `s` es actualmente un HMAC-SHA256 en hex sobre los bytes exactos
de `p`, pero está **reservado en v1**: el iPhone no posee una clave fuera de
banda con la que autenticarlo y, por tanto, no debe tratar esa firma como una
garantía de identidad. El helper la verifica contra sí mismo para detectar
errores al emitir; un futuro servidor de pairing puede darle una función de
autenticación sin cambiar el envelope.

El QR **sí contiene un secreto**: `t` es una credencial bearer válida durante
unos minutos y una sola vez. Lo que el QR no contiene son las credenciales de
larga duración de Hermes. La clave del gateway y el login del dashboard solo
se entregan en la respuesta del canje.

## 2. El canje entrega la configuración

```http
POST {c}
Content-Type: application/json

{"token":"<t>","device_name":"iPhone"}
```

| respuesta | significado |
| --- | --- |
| `200` | `{"profile":"radar-ia","gateway":{"url","key"},"dashboard":{"url","username","password"}\|null}` |
| `410` | token caducado o ya usado |
| `404` | token inexistente |
| `403` | origen de red no permitido |

Antes de guardar nada, Alice valida la respuesta: gateway y dashboard deben
usar `http` o `https`, no pueden llevar credenciales embebidas en la URL y
deben pertenecer al **mismo host** que el endpoint de canje (los puertos pueden
ser distintos). La clave del gateway y, cuando existe dashboard, usuario y
contraseña, no pueden estar vacíos.

Después Alice usa los mismos caminos que la configuración manual:
`AppStore.connect` verifica y guarda la clave del gateway en Keychain y
`AppStore.connectDashboard` hace lo mismo con el dashboard. `dashboard: null`
es una configuración válida y deja solo el gateway conectado.

El token se consume al entregar la respuesta. Si el canje ya funcionó pero la
conexión posterior al gateway falla, **Retry no vuelve a canjear el QR**: el
cliente conserva en memoria esa configuración durante el flujo y vuelve a
intentar solo la conexión. Si el gateway conecta y el dashboard no, Alice lo
muestra como configuración parcial y permite reintentar solo esos servicios.

## 3. Modelo de seguridad (v1)

- **TTL corto**: el token y la fecha anunciada usan el mismo reloj del almacén
  en memoria; al llegar a la expiración deja de ser canjeable.
- **Un solo uso**: después de un `200`, el mismo token no entrega las
  credenciales otra vez.
- **QR local al Mac**: la página `GET /` que permite ver el QR grande solo
  responde a loopback. Otro equipo de la tailnet no puede visitar el helper y
  obtener una copia de la credencial bearer.
- **Canje limitado por red**: por defecto `POST /claim` acepta loopback y
  `100.64.0.0/10`. `--allow-lan` amplía esto solo a rangos de LAN privada; no
  abre el canje a direcciones públicas arbitrarias.
- **Sin persistencia del token**: el almacén vive en memoria. Reiniciar el
  helper invalida el QR anterior; al caducar, el helper cierra el servidor y
  termina.
- **Sin redirects en iOS**: el POST que lleva `t` no sigue redirecciones, por lo
  que un `30x` no puede mover la credencial bearer a otro host.
- **Respuestas no cacheables**: la página del QR y el canje llevan
  `Cache-Control: no-store`.
- `device_name` no autentica nada. Se sanea y se usa únicamente como etiqueta
  legible para saber qué dispositivo se emparejó.

La seguridad de v1 presupone que el usuario confía en el Mac/QR que está
mirando y en su tailnet. El esquema URL personalizado `alice://` es suficiente
para esta primera distribución controlada, pero no ofrece la propiedad de
asociación exclusiva de un Universal Link. Si Alice se distribuye de forma
abierta, migrar el punto de entrada a un Universal Link asociado al dominio
del producto sería una mejora de endurecimiento; el protocolo de canje puede
seguir siendo el mismo.

## 4. Experiencia en el Mac y el iPhone

`npm run pair`:

1. resuelve el perfil de Hermes sin elegir silenciosamente entre varios;
2. lee gateway/dashboard en modo solo lectura;
3. obtiene la IPv4 de Tailscale (o usa `--address`);
4. pinta el QR en Terminal;
5. deja disponible `http://localhost:8643/` para verlo grande;
6. termina al emparejar o al caducar.

El QR de la app Cámara abre `alice://pair?…`; iOS arranca Alice y muestra la
confirmación. Dentro de Alice, `Connect → Scan QR` usa VisionKit y ofrece pegar
el enlace como alternativa para simulador, permisos denegados o códigos que
llegaron como texto.

## 5. Port futuro al dashboard de Hermes

La dirección a largo plazo es mover el emisor/canje al dashboard oficial de
Hermes sin bifurcar `hermes-agent` hoy. Ese servidor debe conservar:

- el envelope versionado de §1;
- token corto y de un solo uso;
- respuesta de §2;
- límites de origen/transporte equivalentes o más fuertes;
- no-cache y protección frente a redirects/entrega a hosts inesperados.

El frontend de Hermes puede entonces añadir “Conectar Alice”, pedir una oferta
y pintar el QR. Mientras respete el contrato, nada cambia en el cliente iOS.
