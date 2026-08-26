# Alice

Interfaz para hablar con tu [Hermes Agent](https://hermes-agent.nousresearch.com).

La clave de Hermes **no está en este repositorio**. Nadie que clone el código puede usar tu agente.

## Cómo se guarda la clave

- **En la nube:** el servidor la guarda en una cookie httpOnly, cifrada. El navegador no puede leerla.
- **En este Mac:** vive solo en memoria mientras tienes la pestaña abierta. Se borra al cerrarla.
- Al desplegar, define `HERMES_COOKIE_SECRET` (un valor largo y aleatorio). Sin eso, la cookie se cifra con una clave temporal de ese proceso.

## Arranque

```bash
cp .env.example .env
# Edita .env y pon HERMES_COOKIE_SECRET
npm install
npm run dev
```

Abre la app, ve a **Conectar** e introduce la dirección y la clave de *tu* Hermes.

## Qué no hagas

- No subas `.env`
- No pegues la clave en issues, README ni capturas
- No actives `direct_model_requests` públicos sin clave en tu Hermes
