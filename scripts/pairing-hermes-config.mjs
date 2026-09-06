/**
 * Read-only look at the Hermes home (~/.hermes) to learn what a pairing QR
 * has to hand over: the gateway address and key, and the dashboard login.
 * Nothing here writes, prints, or mutates; the caller decides what leaves
 * the process, and the claim response body is the only place secrets go.
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";

/**
 * The subset of dotenv syntax Hermes' own .env files use: KEY=VALUE, blank
 * lines and # comments, optional `export`, optional single or double
 * quotes. Values may contain `=`.
 * @param {string} text
 * @returns {Record<string, string>}
 */
export function parseEnvFile(text) {
  /** @type {Record<string, string>} */
  const values = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const withoutExport = line.replace(/^export\s+/, "");
    const equals = withoutExport.indexOf("=");
    if (equals <= 0) continue;
    const key = withoutExport.slice(0, equals).trim();
    let value = withoutExport.slice(equals + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (key) values[key] = value;
  }
  return values;
}

function readEnvFile(filePath) {
  if (!existsSync(filePath)) return null;
  return parseEnvFile(readFileSync(filePath, "utf8"));
}

/**
 * Profiles launchd knows about, by the name baked into
 * `ai.hermes.gateway-<profile>.plist`. The machine's own word for what is
 * active, and the one that survives config.yaml rewrites. Disabled agents
 * (`.disabled-…` suffixes seen in the wild) do not count.
 * @param {string} launchAgentsDir
 * @returns {string[]}
 */
export function launchdGatewayProfiles(launchAgentsDir) {
  try {
    return readdirSync(launchAgentsDir)
      .filter((name) => /^ai\.hermes\.gateway-.+\.plist$/.test(name))
      .map((name) => name.slice("ai.hermes.gateway-".length, -".plist".length))
      .filter((name) => !name.includes(".disabled"))
      .sort();
  } catch {
    return [];
  }
}

/**
 * `active_profile:` from config.yaml — the one yaml key the helper needs,
 * read as a line match rather than pulling in a yaml parser.
 * @param {string} hermesHome
 * @returns {string | null}
 */
export function configActiveProfile(hermesHome) {
  try {
    const text = readFileSync(path.join(hermesHome, "config.yaml"), "utf8");
    const match = text.match(
      /^active_profile:\s*["']?([\w.-]+)["']?\s*(?:#.*)?$/m,
    );
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

/**
 * @param {{ hermesHome: string, profile: string }} options
 * @returns {{ key: string, port: number } | null} Null when the profile has
 * no readable gateway key — the QR cannot be built without it.
 */
export function readProfileGateway({ hermesHome, profile }) {
  const env = readEnvFile(path.join(hermesHome, "profiles", profile, ".env"));
  if (!env?.API_SERVER_KEY) return null;
  const port = Number.parseInt(env.API_SERVER_PORT ?? "", 10);
  return {
    key: env.API_SERVER_KEY,
    port: Number.isInteger(port) ? port : 8642,
  };
}

/**
 * Dashboard basic-auth credentials from the Hermes home `.env`. Absent or
 * empty means the install runs its dashboard without them; Alice treats the
 * dashboard as optional and so does the pairing response.
 * @param {string} hermesHome
 * @returns {{ username: string, password: string } | null}
 */
export function readDashboardAuth(hermesHome) {
  const env = readEnvFile(path.join(hermesHome, ".env"));
  const username = env?.HERMES_DASHBOARD_BASIC_AUTH_USERNAME;
  const password = env?.HERMES_DASHBOARD_BASIC_AUTH_PASSWORD;
  if (!username || !password) return null;
  return { username, password };
}
