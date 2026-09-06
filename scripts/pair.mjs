#!/usr/bin/env node
/**
 * Conectar Alice — shows on this Mac the QR that pairs the Alice iPhone app
 * with the Hermes running here. Reads the Hermes home read-only, mints a
 * one-time bearer pairing link (docs/pairing.md), serves the claim endpoint
 * until the token is used or expires, and exits immediately afterwards.
 *
 * No daemon, no state on disk: run `npm run pair` again any time you want a
 * fresh QR.
 */
import { spawnSync } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import path from "node:path";
import process from "node:process";

import QRCode from "qrcode";

import { createClaimStore } from "./pairing-claims.mjs";
import {
  configActiveProfile,
  launchdGatewayProfiles,
  readDashboardAuth,
  readProfileGateway,
} from "./pairing-hermes-config.mjs";
import {
  advertisedHost,
  claimOriginAllowed,
  isLoopback,
} from "./pairing-network.mjs";
import { buildPairingLink } from "./pairing-protocol.mjs";

const CLAIM_PORT_DEFAULT = 8643;
const DASHBOARD_PORT_DEFAULT = 9119;

function fail(message) {
  console.error(`\n${message}\n`);
  process.exit(1);
}

function usage() {
  console.log(`Uso: npm run pair [-- <opciones>]

  --profile <nombre>   Perfil Hermes cuyo gateway anunciar el QR
                       (por defecto: el activo si puede resolverse sin ambigüedad)
  --address <ip>       IPv4/hostname que anunciar el QR (por defecto: Tailscale)
  --port <puerto>      Puerto del canje (por defecto ${CLAIM_PORT_DEFAULT})
  --dashboard-port <p> Puerto del dashboard (por defecto ${DASHBOARD_PORT_DEFAULT})
  --hermes-home <ruta> Carpeta de Hermes (por defecto ~/.hermes)
  --help`);
}

function validPort(value) {
  return Number.isInteger(value) && value >= 1 && value <= 65535;
}

function parseArgs(argv) {
  const options = {
    profile: null,
    address: null,
    port: CLAIM_PORT_DEFAULT,
    dashboardPort: DASHBOARD_PORT_DEFAULT,
    hermesHome: path.join(homedir(), ".hermes"),
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const value = (name) => {
      i += 1;
      if (i >= argv.length) fail(`Falta el valor de ${name}.`);
      return argv[i];
    };
    switch (argv[i]) {
      case "--profile":
        options.profile = value("--profile");
        break;
      case "--address":
        options.address = value("--address");
        break;
      case "--port":
        options.port = Number.parseInt(value("--port"), 10);
        break;
      case "--dashboard-port":
        options.dashboardPort = Number.parseInt(value("--dashboard-port"), 10);
        break;
      case "--hermes-home":
        options.hermesHome = path.resolve(value("--hermes-home"));
        break;
      case "--help":
        options.help = true;
        break;
      default:
        fail(`Opción que no reconozco: ${argv[i]} (prueba --help).`);
    }
  }
  if (!validPort(options.port)) fail("El puerto del canje no es válido.");
  if (!validPort(options.dashboardPort)) {
    fail("El puerto del dashboard no es válido.");
  }
  return options;
}

/** The IPv4 address iPhone and Mac share: the tailnet. */
function tailscaleIPv4() {
  const bin = spawnSync("which", ["tailscale"], { encoding: "utf8" });
  if (bin.status !== 0) return null;
  const status = spawnSync("tailscale", ["status", "--json"], {
    encoding: "utf8",
    timeout: 15_000,
  });
  if (status.status !== 0) return null;
  let data;
  try {
    data = JSON.parse(status.stdout || "{}");
  } catch {
    return null;
  }
  const ips = data.Self?.TailscaleIPs ?? [];
  return ips.find((ip) => /^\d+\.\d+\.\d+\.\d+$/.test(ip)) ?? null;
}

function readBody(req, limit = 8 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("cuerpo demasiado grande"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function noStoreHeaders(contentType) {
  return {
    "content-type": contentType,
    "cache-control": "no-store, max-age=0",
    pragma: "no-cache",
    "x-content-type-options": "nosniff",
  };
}

function json(res, status, body) {
  res.writeHead(status, noStoreHeaders("application/json; charset=utf-8"));
  res.end(JSON.stringify(body));
}

function tokenMatches(candidate, expected) {
  if (typeof candidate !== "string") return false;
  const left = Buffer.from(candidate, "utf8");
  const right = Buffer.from(expected, "utf8");
  return left.length === right.length && timingSafeEqual(left, right);
}

/**
 * Alice cannot use a QR whose advertised gateway is not reachable through
 * the advertised address. Probe the same two endpoints AppStore.connect uses
 * before minting a token, so a loopback-only/dead gateway fails on the Mac
 * with one useful message instead of after the iPhone has consumed its QR.
 */
async function probeGateway(baseURL, key) {
  const headers = {
    Accept: "application/json",
    Authorization: `Bearer ${key}`,
    "X-Hermes-Session-Token": key,
  };
  const statuses = [];
  let transportError = null;

  for (const route of ["v1/capabilities", "v1/models"]) {
    try {
      const response = await fetch(new URL(route, `${baseURL}/`), {
        headers,
        redirect: "manual",
        cache: "no-store",
        signal: AbortSignal.timeout(6_000),
      });
      statuses.push(`${route}: ${response.status}`);
      if (response.status >= 200 && response.status < 300) return;
      if (response.status === 401 || response.status === 403) {
        fail(
          "El gateway de Hermes responde, pero ha rechazado su propia clave. " +
            "Revisa API_SERVER_KEY antes de emparejar Alice.",
        );
      }
    } catch (error) {
      transportError = error;
    }
  }

  const detail = statuses.length > 0 ? ` (${statuses.join(", ")})` : "";
  const cause = transportError?.message ? `\n${transportError.message}` : "";
  fail(
    `El gateway de Hermes no está utilizable en ${baseURL}${detail}.\n` +
      "Alice necesita que ese gateway sea alcanzable desde la dirección anunciada." +
      cause,
  );
}

function pairPage(link, expiresAtMs) {
  return QRCode.toDataURL(link, { width: 512, margin: 2 }).then(
    (dataUrl) => `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Conectar Alice</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         font: 16px/1.5 -apple-system, system-ui, sans-serif;
         background: #f6f4ef; color: #1d1c19; }
  main { text-align: center; padding: 40px 24px; max-width: 420px; }
  h1 { font-size: 28px; margin: 0 0 4px; }
  p.sub { margin: 0 0 24px; color: #6b6a64; }
  img { width: 320px; height: 320px; background: #fff; border-radius: 16px;
        box-shadow: 0 8px 30px rgb(0 0 0 / 10%); }
  ol { text-align: left; display: inline-block; margin: 24px 0 0; color: #3d3c37; }
  .expires { margin-top: 20px; font-size: 13px; color: #6b6a64; }
  code { font-size: 12px; color: #6b6a64; word-break: break-all; }
</style>
</head>
<body>
<main>
  <h1>Conectar Alice</h1>
  <p class="sub">Empareja la app del iPhone con tu Hermes</p>
  <img src="${dataUrl}" alt="Código QR de emparejamiento de Alice">
  <ol>
    <li>Instala Alice en el iPhone si no la tienes.</li>
    <li>Abre la app <b>Cámara</b> y apunta al código.</li>
    <li>Toca el aviso para abrir Alice y confirma.</li>
  </ol>
  <p class="expires">Caduca en <span id="left">…</span>.</p>
  <p><code>${link}</code></p>
</main>
<script>
  const expires = ${expiresAtMs};
  const left = document.getElementById("left");
  function tick() {
    const seconds = Math.max(0, Math.round((expires - Date.now()) / 1000));
    left.textContent = seconds >= 60
      ? Math.ceil(seconds / 60) + " min"
      : seconds + " s";
  }
  tick();
  setInterval(tick, 1000);
</script>
</body>
</html>`,
  );
}

function chooseProfile(options) {
  if (options.profile) return options.profile;

  const profileDir = (name) =>
    existsSync(path.join(options.hermesHome, "profiles", name));
  const fromLaunchd = launchdGatewayProfiles(
    path.join(homedir(), "Library", "LaunchAgents"),
  ).filter(profileDir);
  const active = configActiveProfile(options.hermesHome);

  if (active && (fromLaunchd.length === 0 || fromLaunchd.includes(active))) {
    return active;
  }
  if (fromLaunchd.length === 1) return fromLaunchd[0];
  if (fromLaunchd.length > 1) {
    fail(
      "Hay varios gateways Hermes configurados (" +
        `${fromLaunchd.join(", ")}). Vuelve a ejecutar el comando con ` +
        "--profile <nombre> para elegir cuál conectar.",
    );
  }
  return active ?? "default";
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }

  const profile = chooseProfile(options);
  const gateway = readProfileGateway({
    hermesHome: options.hermesHome,
    profile,
  });
  if (!gateway) {
    fail(
      `No he encontrado una configuración válida del gateway del perfil "${profile}" en ` +
        `${options.hermesHome}/profiles/${profile}/.env.\n` +
        "Indica otro perfil con --profile o la carpeta con --hermes-home.",
    );
  }
  const dashboard = readDashboardAuth(options.hermesHome);

  const rawAddress =
    options.address ??
    tailscaleIPv4() ??
    fail(
      "No he podido averiguar la IPv4 de Tailscale.\n" +
        "Conecta Tailscale, o pasa una IPv4/hostname alcanzable con --address.",
    );
  const address = advertisedHost(rawAddress);
  if (!address) {
    fail("La dirección anunciada no es una IPv4 o un hostname válido.");
  }

  const gatewayUrl = `http://${address}:${gateway.port}`;
  const dashboardUrl = `http://${address}:${options.dashboardPort}`;
  const claimPort = options.port;
  const claimUrl = `http://${address}:${claimPort}/claim`;

  await probeGateway(gatewayUrl, gateway.key);

  // One token, one claim, one in-memory lifetime. The store's expiry is the
  // expiry written into the QR so client and server are on the same boundary.
  const store = createClaimStore();
  const token = randomBytes(24).toString("base64url");
  const expiresAtMs = store.issue(token);
  const offer = {
    c: claimUrl,
    t: token,
    e: Math.floor(expiresAtMs / 1000),
    pr: profile,
  };
  const link = buildPairingLink(offer);

  const config = {
    profile,
    gateway: { url: gatewayUrl, key: gateway.key },
    dashboard: dashboard
      ? {
          url: dashboardUrl,
          username: dashboard.username,
          password: dashboard.password,
        }
      : null,
  };

  let claimed = false;
  const server = createServer(async (req, res) => {
    let url;
    try {
      // Never use the untrusted Host header as a URL base. Only the pathname
      // matters to this tiny server.
      url = new URL(req.url ?? "/", "http://localhost");
    } catch {
      json(res, 400, { error: "bad_request" });
      return;
    }

    if (req.method === "GET" && url.pathname === "/") {
      // The QR is itself a bearer credential. Tailnet peers may claim it only
      // if they already possess it; they must not be able to fetch a copy from
      // the helper. The browser convenience page is therefore Mac-local.
      if (!isLoopback(req.socket.remoteAddress ?? "")) {
        json(res, 404, { error: "not_found" });
        return;
      }
      res.writeHead(200, noStoreHeaders("text/html; charset=utf-8"));
      res.end(await pairPage(link, expiresAtMs));
      return;
    }

    if (req.method === "POST" && url.pathname === "/claim") {
      if (!claimOriginAllowed(req.socket.remoteAddress ?? "")) {
        console.log(
          `Petición de canje rechazada desde ${req.socket.remoteAddress} (fuera de la tailnet).`,
        );
        json(res, 403, { error: "forbidden" });
        return;
      }

      let deviceName = "iPhone";
      try {
        const body = JSON.parse(await readBody(req));
        if (typeof body.device_name === "string" && body.device_name.trim()) {
          deviceName = [...body.device_name.trim()]
            .filter((ch) => {
              const code = ch.codePointAt(0);
              return code !== undefined && code >= 32 && code !== 127;
            })
            .join("")
            .slice(0, 64);
        }
        if (!tokenMatches(body.token, offer.t)) throw new Error("token");
      } catch {
        json(res, 404, { error: "unknown" });
        return;
      }

      const outcome = store.consume(offer.t);
      if (outcome !== "ok") {
        console.log(
          `Intento de canje rechazado (${outcome}) desde ${deviceName}.`,
        );
        json(res, 410, { error: outcome });
        return;
      }

      claimed = true;
      console.log(`Emparejado: ${deviceName} (${req.socket.remoteAddress}).`);
      res.writeHead(200, noStoreHeaders("application/json; charset=utf-8"));
      res.end(JSON.stringify(config), () => {
        // Leave only after the response is on the wire; the helper's job is
        // done the moment a phone has the configuration.
        setTimeout(() => process.exit(0), 300);
      });
      return;
    }

    json(res, 404, { error: "unknown" });
  });

  server.on("error", (error) => {
    if (error.code === "EADDRINUSE") {
      fail(
        `El puerto ${claimPort} ya está en uso: probablemente otro ` +
          "`npm run pair` sigue abierto. Ciérralo o usa --port.",
      );
    }
    fail(`No he podido abrir el servidor de canje: ${error.message}`);
  });

  server.listen(claimPort, "0.0.0.0", async () => {
    const minutes = Math.max(1, Math.ceil((expiresAtMs - Date.now()) / 60000));
    console.log("");
    console.log("Conectar Alice — escanea con la app Cámara del iPhone:");
    console.log("");
    try {
      console.log(await QRCode.toString(link, { type: "terminal", small: true }));
    } catch {
      // El QR ASCII es un lujo; el enlace y la página local siguen disponibles.
    }
    console.log(`  ${link}`);
    console.log("");
    console.log(`  Perfil: ${profile}`);
    console.log(`  Gateway: ${gatewayUrl}`);
    console.log(
      dashboard
        ? `  Dashboard: ${dashboardUrl} (${dashboard.username})`
        : "  Dashboard: sin credenciales en ~/.hermes/.env (se omite)",
    );
    console.log(`  Caduca en ${minutes} minutos y vale una sola vez.`);
    console.log(
      "  En este Mac también puedes abrir http://localhost:" +
        `${claimPort}/ para ver el QR grande.`,
    );
    console.log("");
  });

  const expiryDelay = Math.max(0, expiresAtMs - Date.now()) + 250;
  const expiryTimer = setTimeout(() => {
    if (claimed) return;
    console.log("\nEl QR ha caducado. Ejecuta `npm run pair` para crear otro.");
    server.close(() => process.exit(0));
  }, expiryDelay);
  expiryTimer.unref?.();

  process.on("SIGINT", () => {
    console.log(claimed ? "" : "\nSin emparejar. Adiós.");
    process.exit(0);
  });
}

main().catch((error) => fail(error?.stack ?? String(error)));
