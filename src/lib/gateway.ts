export type GatewayMode = "direct" | "proxy";

export type GatewayPlace = "cloud" | "mac";

export type GatewayStatus = "idle" | "checking" | "live" | "down";

export type HermesModelOption = {
  id: string;
  label: string;
  provider: string;
};

export type GatewayMeta = {
  model: string;
  provider?: string;
  models?: HermesModelOption[];
  platform?: string;
  skills?: string[];
  probedAt: number;
  mode: GatewayMode;
  place?: GatewayPlace;
};

export type ChatEvent =
  | { type: "delta"; text: string }
  | { type: "tool"; name: string; status: "start" | "done"; detail?: string }
  | { type: "error"; message: string };

export type ProbeCode = "invalid" | "private" | "unauthorized" | "unreachable" | "cors" | "not_hermes";

export type ProbeResult =
  | {
      ok: true;
      model: string;
      provider?: string;
      models?: HermesModelOption[];
      platform?: string;
      skills?: string[];
      mode: GatewayMode;
    }
  | { ok: false; code: ProbeCode; error: string };

export class GatewayError extends Error {
  code: ProbeCode;
  constructor(code: ProbeCode, message: string) {
    super(message);
    this.code = code;
  }
}

const FAIL = "No se ha podido conectar.";

export function friendlyProbeError(code?: ProbeCode): string {
  if (code === "unauthorized") return "La clave no es correcta.";
  if (code === "invalid") return "Revisa la dirección.";
  return FAIL;
}

let macSessionKey: string | null = null;

export function setMacSessionKey(key: string | null) {
  macSessionKey = key;
}

export function getMacSessionKey() {
  return macSessionKey;
}

export function normalizeGatewayUrl(raw: string): string {
  let s = raw.trim();
  if (!s) throw new GatewayError("invalid", FAIL);
  if (s.length > 512) throw new GatewayError("invalid", FAIL);
  if (!/^https?:\/\//i.test(s)) s = `http://${s}`;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    throw new GatewayError("invalid", FAIL);
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") {
    throw new GatewayError("invalid", FAIL);
  }
  if (u.username || u.password) {
    throw new GatewayError("invalid", FAIL);
  }
  u.hash = "";
  u.search = "";
  let path = u.pathname.replace(/\/+$/, "");
  if (path.endsWith("/v1")) path = path.slice(0, -3);
  path = path.replace(/\/+$/, "");
  return u.origin + (path && path !== "/" ? path : "");
}

export function assertGatewayKey(raw: string): string {
  const k = raw.trim();
  if (k.length < 8 || k.length > 256) throw new GatewayError("invalid", FAIL);
  if (/[\u0000-\u001f\u007f]/.test(k)) {
    throw new GatewayError("invalid", FAIL);
  }
  return k;
}

export function isPrivateHostname(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (
    h === "localhost" ||
    h.endsWith(".localhost") ||
    h.endsWith(".local") ||
    h === "::1" ||
    h === "0.0.0.0" ||
    h === "metadata.google.internal" ||
    h === "metadata" ||
    h === "kubernetes"
  ) {
    return true;
  }
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (!m) return false;
  const a = Number(m[1]);
  const b = Number(m[2]);
  const c = Number(m[3]);
  const d = Number(m[4]);
  if ([a, b, c, d].some((n) => n > 255)) return false;
  if (a === 10 || a === 127 || a === 0) return true;
  if (a === 192 && b === 168) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 169 && b === 254) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  if (a >= 224) return true;
  return false;
}

export async function forgetHermesSecret() {
  setMacSessionKey(null);
}
