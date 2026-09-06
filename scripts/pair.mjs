#!/usr/bin/env node
/**
 * Conectar Alice — shows on this Mac the QR that pairs the Alice iPhone app
 * with the Hermes running here. Reads the Hermes home read-only, mints a
 * one-time signed deep link (docs/pairing.md), serves the claim endpoint
 * until the token is used or expires, and exits the moment a phone pairs.
 *
 * No daemon, no state on disk: run `npm run pair` again any time you want a
 * fresh QR.
 */
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import process from "node:process";

import QRCode from "qrcode";

import { createClaimStore } from "./pairing-claims.mjs";
import {
  PAIR_TTL_MS,
  buildPairingLink,
  verifyPairingLink,
} from "./pairing-protocol.mjs";
import {
  configActiveProfile,
  launchdGatewayProfiles,
  readDashboardAuth,
  readProfileGateway,
} from "./pairing-hermes-config.mjs";

const CLAIM_PORT_DEFAULT = 8643;
const DASHBOARD_PORT_DEFAULT = 9119;

function fail(message) {
  console.error(`\n${message}\n`);
  process.exit(1);
}

function usage() {
  console.log(`Uso: npm run pair [-- <opciones>]

  --profile <nombre>   Perfil Hermes cuyo gateway anunciar el QR
                       (por defecto: el que lanza launchd, o active_profile)
  --address <ip>       IP que anunciar el QR (por defecto: la de Tailscale)
  --port <puerto>      Puerto del canje (por defecto ${CLAIM_PORT_DEFAULT})
  --dashboard-port <p> Puerto del dashboard (por defecto ${DASHBOARD_PORT_DEFAULT})
  --hermes-home <ruta> Carpeta de Hermes (por defecto ~/.hermes)
  --allow-lan          Permitir el canje desde cualquier red de este Mac
  --help`);
}

function parseArgs(argv) {
  const options = {
    profile: null,
    address: null,
    port: CLAIM_PORT_DEFAULT,
    dashboardPort: DASHBOARD_PORT_DEFAULT,
    hermesHome: path.join(homedir(), ".hermes"),
    allowLan: false,
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
      case "--allow-lan":
        options.allowLan = true;
        break;
      case "--help":
        options.help = true;
        break;
      default:
        fail(`Opción que no reconozco: ${argv[i]} (prueba --help).`);
    }
  }
  if (
    !Number.isInteger(options.port) ||
    options.port < 1 ||
    options.port > 65535
  ) {
    fail("El puerto del canje no es válido.");
  }
  return options;
}

/**
 * The address iPhone and Mac share: the tailnet. Same discovery that
 * scripts/phone.mjs does for the web app.
 * @returns {string | null}
 */
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
  return ips.find((ip) => !ip.includes(":")) ?? ips[0] ?? null;
}

/**
 * Requests from outside the tailnet must not even see the QR page, let alone
 * claim a token. Loopback is this Mac's own browser.
 * @param {string} rawAddress
 * @param {boolean} allowLan
 */
function originAllowed(rawAddress, allowLan) {
  if (allowLan) return true;
  const address = rawAddress.replace(/^::ffff:/, "");
  if (address === "::1" || address === "127.0.0.1") return true;
  const match = /^(\d+)\.(\d+)\./.exec(address);
  if (!match) return false;
  return (
    match[1] === "100" && Number(match[2]) >= 64 && Number(match[2]) <= 127
  );
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

function pairPage(link, expiresAtMs) {
  return QRCode.toDataURL(link, { width: 512, margin: 2 }).then(
    (dataUrl) => `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
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

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }

  // --- What the QR announces: the Hermes this Mac actually runs. ---
  const profile =
    options.profile ??
    (() => {
      // launchd names every gateway agent `ai.hermes.gateway-<profile>` —
      // but also runs helpers under that prefix (`gateway-reload`), so a
      // candidate only counts if the Hermes home has the profile to match.
      const profileDir = (name) =>
        existsSync(path.join(options.hermesHome, "profiles", name));
      const fromLaunchd = launchdGatewayProfiles(
        path.join(homedir(), "Library", "LaunchAgents"),
      ).filter(profileDir);
      if (fromLaunchd.length === 1) return fromLaunchd[0];
      if (fromLaunchd.length > 1) {
        console.log(
          `Varios perfiles en launchd (${fromLaunchd.join(", ")}); ` +
            `uso ${fromLaunchd[0]}. Elige otro con --profile.`,
        );
        return fromLaunchd[0];
      }
      return null;
    })() ??
    configActiveProfile(options.hermesHome) ??
    "default";

  const gateway = readProfileGateway({
    hermesHome: options.hermesHome,
    profile,
  });
  if (!gateway) {
    fail(
      `No he encontrado la clave del gateway del perfil "${profile}" en ` +
        `${options.hermesHome}/profiles/${profile}/.env (API_SERVER_KEY).\n` +
        "Indica otro perfil con --profile o la carpeta con --hermes-home.",
    );
  }
  const dashboard = readDashboardAuth(options.hermesHome);

  const address =
    options.address ??
    tailscaleIPv4() ??
    fail(
      "No he podido averiguar la IP de Tailscale.\n" +
        "Instala Tailscale (https://tailscale.com/download), conéctalo, o " +
        "pasa la IP a mano con --address.",
    );

  const gatewayUrl = `http://${address}:${gateway.port}`;
  const dashboardUrl = `http://${address}:${options.dashboardPort}`;
  const claimPort = options.port;
  const claimUrl = `http://${address}:${claimPort}/claim`;

  // --- The offer: one token, one claim, five minutes. ---
  const store = createClaimStore();
  const secret = randomBytes(32);
  const token = randomBytes(24).toString("base64url");
  const expiresAtMs = Date.now() + PAIR_TTL_MS;
  const offer = {
    c: claimUrl,
    t: token,
    e: Math.floor(expiresAtMs / 1000),
    pr: profile,
  };
  const link = buildPairingLink(offer, secret);
  // The helper's own round-trip guard: what it shows must verify.
  if (!verifyPairingLink(link, secret).ok) {
    fail("El enlace generado no verifica; hay un error en el protocolo.");
  }
  store.issue(token);

  // --- Serve the QR and the claim until the phone takes it. ---
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
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "x"}`);
    if (!originAllowed(req.socket.remoteAddress ?? "", options.allowLan)) {
      console.log(
        `Petición rechazada desde ${req.socket.remoteAddress} (fuera del tailnet).`,
      );
      res.writeHead(403, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "forbidden" }));
      return;
    }

    if (req.method === "GET" && url.pathname === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(await pairPage(link, expiresAtMs));
      return;
    }

    if (req.method === "POST" && url.pathname === "/claim") {
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
        if (body.token !== offer.t) throw new Error("token");
      } catch {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "unknown" }));
        return;
      }

      const outcome = store.consume(offer.t);
      if (outcome !== "ok") {
        console.log(
          `Intento de canje rechazado (${outcome}) desde ${deviceName}.`,
        );
        res.writeHead(410, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: outcome }));
        return;
      }

      console.log(`Emparejado: ${deviceName} (${req.socket.remoteAddress}).`);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(config), () => {
        // Leave only after the response is on the wire; the helper's job is
        // done the moment a phone has the configuration.
        setTimeout(() => process.exit(0), 300);
      });
      claimed = true;
      return;
    }

    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unknown" }));
  });

  server.on("error", (error) => {
    if (error.code === "EADDRINUSE") {
      fail(
        `El puerto ${claimPort} ya está en uso: probablemente otro ` +
          "`npm run pair' sigue abierto. Ciérralo o usa --port.",
      );
    }
    fail(`No he podido abrir el servidor de canje: ${error.message}`);
  });

  server.listen(claimPort, "0.0.0.0", async () => {
    const minutes = Math.round(PAIR_TTL_MS / 60000);
    console.log("");
    console.log("Conectar Alice — escanea con la app Cámara del iPhone:");
    console.log("");
    try {
      console.log(
        await QRCode.toString(link, { type: "terminal", small: true }),
      );
    } catch {
      // El QR ASCII es un lujo; el enlace y la página web son el camino real.
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
      "  También puedes abrir http://localhost:" +
        `${claimPort}/ para ver el QR grande.`,
    );
    console.log("");
  });

  process.on("SIGINT", () => {
    console.log(claimed ? "" : "\nSin emparejar. Adiós.");
    process.exit(0);
  });
}

main().catch((error) => fail(error?.stack ?? String(error)));
