#!/usr/bin/env node
import { spawn } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Prefer `.alice/app-env.json`; `.grok/app-env.json` remains as the legacy
// location so existing local setups keep working.
export const APP_ENV_REL_PATHS = [".alice/app-env.json", ".grok/app-env.json"];
export const APP_ENV_REL_PATH = APP_ENV_REL_PATHS[0];
const VITE_PREFIX = "VITE_";

export function parseAppEnv(text) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return {};
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
    return {};
  const env = {};
  for (const [key, value] of Object.entries(parsed)) {
    if (!key.startsWith(VITE_PREFIX)) continue;
    if (typeof value !== "string") continue;
    env[key] = value;
  }
  return env;
}

export function readAppEnv(root) {
  for (const relPath of APP_ENV_REL_PATHS) {
    try {
      return parseAppEnv(readFileSync(join(root, relPath), "utf8"));
    } catch {
      /* try the next location */
    }
  }
  return {};
}

export function mergeAppEnv(appEnv, processEnv) {
  return { ...appEnv, ...processEnv };
}

export function applyCommandDefaults(command, args, env) {
  const next = { ...env };
  const viteDev = command === "vite" && args[0] === "dev";
  const pgliteModeIsExplicit =
    next.ALICE_PGLITE_MEMORY !== undefined ||
    next.ALICE_PGLITE_DIR !== undefined;

  // Codex preview processes may be terminated without receiving a shutdown
  // signal. A disk-backed PGlite instance can then retain an unrecoverable
  // Postgres control state. The dev preview does not need server-side
  // persistence: conversations and preferences already live in per-user
  // browser storage, while production uses DATABASE_URL. Keep `npm run dev`
  // restart-safe by default, while preserving an explicit persistent PGlite
  // configuration for developers who need one.
  if (viteDev && !pgliteModeIsExplicit) {
    next.ALICE_PGLITE_MEMORY = "1";
  }
  return next;
}

export function exitStatusFromChild(code, signal) {
  if (signal) {
    const signo = osConstants.signals[signal];
    return 128 + (typeof signo === "number" ? signo : 1);
  }
  return code ?? 1;
}

export function projectRoot() {
  return dirname(dirname(fileURLToPath(import.meta.url)));
}

export function isMainModule(moduleUrl) {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === fileURLToPath(moduleUrl);
  } catch {
    return false;
  }
}

function main(argv) {
  const [command, ...args] = argv;
  if (!command) {
    console.error("usage: node scripts/with-app-env.mjs <command> [args…]");
    process.exit(2);
  }
  const env = applyCommandDefaults(
    command,
    args,
    mergeAppEnv(readAppEnv(projectRoot()), process.env),
  );
  const child = spawn(command, args, { stdio: "inherit", env });
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(signal, () => child.kill(signal));
  }
  child.on("error", (err) => {
    console.error(
      `[with-app-env] failed to run ${command}:`,
      err?.message || err,
    );
    process.exit(127);
  });
  child.on("exit", (code, signal) => {
    process.exit(exitStatusFromChild(code, signal));
  });
}

if (isMainModule(import.meta.url)) {
  main(process.argv.slice(2));
}
