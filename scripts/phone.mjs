#!/usr/bin/env node
/**
 * Expose Alice at the MagicDNS HTTPS name. Funnel is required for Safari on
 * iPhone: Private Relay / public DNS will not complete TLS against Serve-only.
 */
import { spawnSync } from "node:child_process";

function tailscale(args, opts = {}) {
  return spawnSync("tailscale", args, { encoding: "utf8", ...opts });
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

function main() {
  const bin = spawnSync("which", ["tailscale"], { encoding: "utf8" });
  if (bin.status !== 0) {
    fail("Instala Tailscale en este Mac (https://tailscale.com/download) y vuelve a intentarlo.");
  }

  let status = tailscale(["status", "--json"]);
  if (status.status !== 0) {
    console.log("Arrancando Tailscale…");
    spawnSync("open", ["-a", "Tailscale"]);
    const up = tailscale(["up"], { timeout: 60_000 });
    if (up.status !== 0) {
      fail(
        (up.stderr || up.stdout || "No se ha podido conectar Tailscale.").trim() +
          "\nAbre la app Tailscale en este Mac e inicia sesión con marcfreixanet@gmail.com.",
      );
    }
    status = tailscale(["status", "--json"]);
  }

  let data;
  try {
    data = JSON.parse(status.stdout || "{}");
  } catch {
    fail("Tailscale no ha respondido. Abre la app Tailscale en este Mac.");
  }
  if (!data.Self?.Online) {
    spawnSync("open", ["-a", "Tailscale"]);
    const up = tailscale(["up"], { timeout: 60_000 });
    if (up.status !== 0 || !JSON.parse(tailscale(["status", "--json"]).stdout || "{}").Self?.Online) {
      fail("Tailscale sigue parado. Ábrelo en la barra de menú y conéctalo.");
    }
    data = JSON.parse(tailscale(["status", "--json"]).stdout || "{}");
  }

  const host = String(data.Self?.DNSName || "").replace(/\.$/, "");
  if (!host) fail("No hay nombre MagicDNS. Activa MagicDNS en la consola de Tailscale.");

  // Safari on iPhone often resolves *.ts.net via public DNS / iCloud Private
  // Relay instead of the tailnet. Serve-only then fails TLS. Funnel is HTTPS
  // with a real Let's Encrypt cert on that same name (login still required).
  tailscale(["serve", "--bg", "8080"]);
  const funnel = tailscale(["funnel", "--bg", "--yes", "8080"]);
  if (funnel.status !== 0) {
    fail((funnel.stderr || funnel.stdout || "tailscale funnel ha fallado.").trim());
  }

  const origin = `https://${host}`;
  console.log("");
  console.log("Alice en el móvil:");
  console.log(`  ${origin}`);
  console.log("");
  console.log("Safari → esa URL → Compartir → Añadir a pantalla de inicio.");
  console.log("Si HTTPS falla: en el iPhone, Tailscale conectado y Relé privado de iCloud apagado.");
  console.log("");
  console.log("Google: en Google Cloud → Clientes → este cliente, añade:");
  console.log(`  ${origin}/api/auth/callback/google`);
  console.log("");
  console.log("Este Mac tiene que estar despierto y con `npm run dev`.");
}

main();
