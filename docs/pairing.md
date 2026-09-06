# Emparejamiento Alice ↔ Hermes (v1)

Configurar Alice hoy a mano exige entender direcciones, puertos y claves. El
emparejamiento por QR lo sustituye por: **Hermes muestra un QR en el Mac →
Alice lo escanea → configurada**.

Implementación actual:

- **Lado Mac**: `npm run pair` (helper de este repo, `scripts/pair.mjs`). Lee la
  configuración de Hermes en modo solo-lectura y sirve el canje hasta que se
  usa o caduca. No modifica `hermes-agent`.
- **Lado iPhone**: app nativa (`ios/Alice/Features/Connect/Pairing/`), con deep
  link `alice://` y escáner propio.

Este documento es el contrato para portar el lado Mac al dashboard de Hermes
(`hermes-agent`, FastAPI en :9119): quien lo implemente debe producir y canjear
exactamente lo que sigue.

## 1. El QR contiene un deep link firmado

```
alice://pair?v=1&p=<base64url(json)>&s=<hex(hmac-sha256(p, secreto))>
```

- `p` — el JSON de la oferta, en base64url **sin padding** (RFC 4648 §5), con
  las claves siempre en este orden para que la firma sea estable:

  | clave | contenido                                                 |
  | ----- | --------------------------------------------------------- |
  | `c`   | URL absoluta del canje (`http://<ip-tailnet>:8643/claim`) |
  | `t`   | token de un solo uso (opaco, aleatorio)                   |
  | `e`   | expiración, época Unix en **segundos**                    |
  | `pr`  | nombre del perfil Hermes (opcional, solo informativo)     |

- `s` — HMAC-SHA256 sobre los bytes exactos de `p`, en hex.
- `v` — versión del formato (`1`).

Ejemplo (recortado):

```
alice://pair?v=1&p=eyJjIjoiaHR0cDovLzEwMC42Ny4yMTMuNDI6OD Y0My9jbGFpbSIsInQiOiI4R…
&s=9f2a…
```

El QR es pequeño a propósito: **ningún secreto viaja en él**. La clave del
gateway y las credenciales del dashboard se entregan solo en la respuesta del
canje, al dispositivo que reclama el token dentro de la ventana de validez.

`s` está **reservado** en v1: solo el emisor conoce el secreto, así que el
cliente no puede verificarla sin fijarlo fuera de banda. Lo que v1 de verdad
exige es el transporte (§3); la firma deja el formato preparado para cuando el
canje viva en el dashboard y convenga pinchar una clave compartida por perfil.

## 2. El canje entrega la configuración

```
POST {c}
Content-Type: application/json

{"token": "<t>", "device_name": "iPhone"}
```

| respuesta | cuerpo                                                                                                     |
| --------- | ---------------------------------------------------------------------------------------------------------- |
| `200`     | `{"profile": "radar-ia", "gateway": {"url", "key"}, "dashboard": {"url", "username", "password"} \| null}` |
| `410`     | `{"error": "expired"}` — caducado, o `{"error": "used"}` — ya usado                                        |
| `404`     | `{"error": "unknown"}` — token inexistente                                                                 |
| `403`     | `{"error": "forbidden"}` — origen de la petición no permitido                                              |

Alice toma exactamente lo que la respuesta trae y lo inyecta por los mismos
caminos que la configuración manual (`AppStore.connect` guarda la clave del
gateway en el Keychain; `AppStore.connectDashboard` hace lo propio con la
contraseña del dashboard). El dashboard es opcional: si la respuesta trae
`dashboard: null`, Alice conecta solo el gateway.

## 3. Modelo de seguridad (v1)

- **TTL de 5 minutos** en la oferta; el canje la aplica con su reloj.
- **Un solo uso**: consumido el token, el canje lo marca usado aunque el TTL
  no haya pasado. Un QR fotografiado vale una vez.
- **Solo tailnet**: el helper rechaza peticiones cuyo origen no esté en
  `100.64.0.0/10` (o loopback) salvo `--allow-lan`. Un extraño que vea el QR
  desde fuera del tailnet no puede canjearlo.
- **Secreto por sesión**: el HMAC se genera por ejecución del helper; reiniciar
  invalida cualquier QR anterior. El almacén de tokens vive en memoria.
- El `device_name` del cuerpo es libre (se recorta y sanea); sirve para el
  registro en consola del Mac y para nombrar el dispositivo en futuras
  pantallas de gestión.

## 4. Pantalla del Mac

`GET /` sobre el mismo puerto del canje sirve una página con el QR grande y
los pasos ("Instala Alice → escanea → Conectar"), para quien prefiera la
Cámara del sistema. El helper pinta además el QR en ASCII en el Terminal.

El QR de la app Cámara abre `alice://pair?…` → iOS arranca Alice y la sheet de
emparejamiento pide confirmación ("Conectando con tu Hermes… → Conectado").
Dentro de la app, `Connect → Scan QR` abre el escáner integrado, con
alternativa de pegar el enlace a mano (útil en simulador).

## 5. Port al dashboard de Hermes

Para mover el lado Mac a `hermes-agent` (follow-up): router FastAPI nuevo en
`hermes_cli/web_routers/` que implemente §1 y §2 tal cual, reutilizando los
patrones de `dashboard_auth/ws_tickets.py` (tickets de un solo uso) y
`gateway/pairing.py` (TTL, límites, almacenamiento 0600). El frontend añade el
botón "Conectar Alice" que pida la oferta (`POST /api/alice/pairing/start`) y
pinte el QR del deep link. Nada cambia en el cliente iOS si el contrato se
respeta.
