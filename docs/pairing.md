# Emparejamiento Alice ↔ Hermes (v1)

Configurar Alice a mano exige entender direcciones, puertos y claves. El
emparejamiento por QR lo sustituye por: **el Dashboard de Hermes muestra un QR
→ Alice lo escanea → configurada con el perfil principal de la instalación**.

Implementación actual:

- **Lado Mac**: el complemento «Alice para Hermes» (`hermes-plugin/` en este
  repositorio), instalado en `~/.hermes/plugins/alice`. Añade la pestaña
  **Alice** al Dashboard y sirve el emparejamiento bajo `/api/plugins/alice/`.
  No toca el código de Hermes, así que `hermes update` nunca choca con él
  (ver `hermes-plugin/README.md`).
- **Lado iPhone**: app nativa (`ios/Alice/Features/Connect/Pairing/`), con deep
  link `alice://` y escáner propio.

## 0. A qué perfil se empareja Alice

El pairing **siempre dirige a Alice hacia el perfil principal de la
instalación**: el perfil que `profiles.list` marca con `is_default` (la raíz
de `~/.hermes`, cuyo `display_name` vive en su `profile.yaml` — en una
instalación típica, "Alice").

No participan de esta decisión:

- el perfil seleccionado en el Dashboard en ese momento,
- el perfil activo persistido (`active_profile`),
- ningún parámetro de la petición: `POST /api/plugins/alice/pairing/session` es
  deliberadamente _profile-less_.

Ese perfil principal es con quien habla el chat Home de la app. Los demás
perfiles ("bots": radar-ia, 537, …) son recursos secundarios: se descubren por
separado (`GET /api/profiles`, donde `is_default: false`) y se dirigen
explícitamente (RPC del dashboard con `profile`), sin sustituir nunca la
conexión Home. El roster de bots de Alice excluye al perfil principal.

## 1. El QR contiene una credencial de emparejamiento

```text
alice://pair?v=1&p=<base64url(json)>
```

`p` es el JSON de la oferta, en base64url **sin padding** (RFC 4648 §5), con
las claves en este orden al emitirlo:

| clave | contenido                                             |
| ----- | ----------------------------------------------------- |
| `c`   | URL absoluta del canje en el Dashboard                |
| `t`   | token de un solo uso, aleatorio y opaco               |
| `e`   | expiración, época Unix en **segundos enteros**        |
| `pr`  | nombre del perfil principal (`default`) — informativo |

`v` vale `1`.

V1 no añade una "firma" que el iPhone no pueda verificar. Un HMAC cuyo secreto
solo conoce el Mac no demostraría nada al cliente y aumentaría el protocolo
sin aportar seguridad. Si una versión futura necesita identidad criptográfica
del emisor, debe introducir un mecanismo verificable (y versionado) con una
historia real de distribución de claves.

El QR **sí contiene un secreto**: `t` es una credencial bearer válida unos
minutos y una sola vez. Lo que el QR no contiene son las credenciales de
larga duración de Hermes. La clave del gateway y el login del dashboard solo
se entregan en la respuesta del canje.

## 2. El canje entrega la configuración

```http
POST {c}
Content-Type: application/json
Authorization: Bearer <t>

{"token":"<t>","device_name":"iPhone"}
```

El iPhone aún no tiene sesión del Dashboard, así que el canje se autentica
por la vía oficial de Hermes para credenciales no interactivas: el complemento
registra un proveedor de tokens que reconoce los códigos pendientes y marca
solo la ruta del canje como autenticable por token. La lista de rutas públicas
de Hermes no cambia. El cuerpo repite `token` por compatibilidad; si lo trae,
debe coincidir con el de la cabecera.

| respuesta | significado                                                                                                                    |
| --------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `200`     | `{"profile":"default","profile_display_name":"Alice","gateway":{"url","key"},"dashboard":{"url","username","password"}\|null}` |
| `410`     | token caducado o ya usado                                                                                                      |
| `401`     | Hermes no reconoce el código (inexistente, caducado o sin cabecera); Alice lo trata como `404`                                 |
| `404`     | token inexistente                                                                                                              |
| `403`     | origen de red no permitido                                                                                                     |

`profile_display_name` es un campo opcional añadido tras la v1 inicial; los
clientes que no lo conozcan lo ignoran. `profile` es siempre el nombre
canónico del perfil principal.

Antes de guardar nada, Alice valida la respuesta: gateway y dashboard deben
usar `http` o `https`, no pueden llevar credenciales embebidas en la URL y
deben pertenecer al **mismo host** que el endpoint de canje (los puertos pueden
ser distintos). La clave del gateway y, cuando existe dashboard, usuario y
contraseña, no pueden estar vacíos. Un canje HTTPS tampoco puede degradar los
servicios persistentes a HTTP, y el POST no sigue redirecciones.

Después Alice usa los mismos caminos que la configuración manual:
`AppStore.connect` verifica y guarda la clave del gateway en Keychain y
`AppStore.connectDashboard` hace lo mismo con el dashboard. `dashboard: null`
es una configuración válida y deja solo el gateway conectado.

El token se consume al entregar la respuesta. Si el canje ya funcionó pero la
conexión posterior al gateway falla, **Retry no vuelve a canjear el QR**: el
cliente conserva en memoria esa configuración durante el flujo y reintenta
solo la conexión; si la sustitución falla, restaura la conexión anterior que
ya tenía. Si el gateway conecta y el dashboard no, Alice lo muestra como
configuración parcial y permite reintentar solo el dashboard.

## 3. Aprovisionamiento del gateway principal

Una instalación puede no tener arrancado el gateway de su perfil principal
(p. ej. porque el único gateway activo es el de un bot). Al pedir una oferta,
el Dashboard lo deja listo de forma **idempotente y conservadora**:

- en el `.env` del perfil principal crea solo lo que falte:
  `API_SERVER_KEY` (aleatoria, nunca rota una existente), `API_SERVER_PORT`
  (primer puerto libre de un rango de candidatos, distinto del de los bots) y
  `API_SERVER_HOST=127.0.0.1` (el gateway escucha solo en local);
- instala (no-op si ya está al día) y arranca el servicio launchd del perfil
  raíz, **sin reiniciarlo si ya está vivo**;
- publica el puerto dentro de la tailnet con un forward TCP de
  `tailscale serve` hacia `127.0.0.1`, solo si falta o apunta a otro sitio —
  nunca toca otros forwards ni el funnel.

Antes de emitir el QR se hace un probe autenticado por la misma ruta que usará
el iPhone (`/v1/capabilities`, `/v1/models`): cuando el gateway escucha en
localhost, el probe va contra `127.0.0.1` a través del forward declarado,
mientras el QR anuncia la dirección Tailscale. Un QR solo se emite si el
gateway realmente responde.

## 4. Modelo de seguridad (v1)

- **TTL corto**: el token y la fecha anunciada usan exactamente el mismo límite
  de segundo del almacén en memoria; al llegar a la expiración deja de ser
  canjeable tanto para el cliente como para el servidor.
- **Un solo uso**: tras un `200`, la entrada se convierte en tumba (sin
  credenciales) y el mismo token solo puede responder `410 used`.
- **Reemplazo**: pedir un código nuevo invalida el anterior vivo del mismo
  origen (IP) para el mismo perfil.
- **Canje solo en la tailnet**: el claim acepta loopback y direcciones
  Tailscale IPv4 de `100.64.0.0/10`, leyendo la dirección **peer** de la
  conexión — nunca cabeceras reenviadas (`X-Forwarded-For`, `Forwarded`,
  `X-Real-IP`), que un cliente LAN podría falsificar; su presencia rechaza la
  petición de plano.
- **Sin persistencia del token**: el almacén vive en memoria. Reiniciar el
  Dashboard invalida el QR anterior.
- **Sin redirects en iOS**: el POST que lleva `t` no sigue redirecciones, por
  lo que un `30x` no puede mover la credencial bearer a otro host.
- **Respuesta confinada al mismo Mac**: el canje no puede entregar credenciales
  para otro hostname y hacer que Alice salte silenciosamente a un tercero.
- **Respuestas no cacheables**: la página del QR y el canje llevan
  `Cache-Control: no-store`.
- **Sin secretos en logs**: los logs y la auditoría registran nombres de
  ajustes, perfil, dispositivo e IP; jamás el valor de claves o contraseñas.
- `device_name` no autentica nada. Se sanea y se usa únicamente como etiqueta
  legible para saber qué dispositivo se emparejó.

La seguridad de v1 presupone que el usuario confía en el Mac/QR que está
mirando y en su tailnet. El esquema URL personalizado `alice://` es suficiente
para esta primera distribución controlada, pero no ofrece la propiedad de
asociación exclusiva de un Universal Link. Si Alice se distribuye de forma
abierta, migrar el punto de entrada a un Universal Link asociado al dominio
del producto sería una mejora de endurecimiento; el protocolo de canje puede
seguir siendo el mismo.

## 5. Experiencia

En el Mac: Dashboard → pestaña **Alice** → **Show pairing code** → QR. En el iPhone:
instalar Alice, escanear con la app Cámara (o `Connect → Scan pairing QR`
dentro de la app), confirmar el nombre del dispositivo y pulsar Connect.
"Conectando con tu Hermes…" → "Conectado" sobre el perfil principal; los bots
siguen disponibles y gestionables aparte.
