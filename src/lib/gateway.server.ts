import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import {
  assertGatewayKey,
  enrichWithModelOptions,
  eventFromChunk,
  GatewayError,
  isPrivateHostname,
  modelFromList,
  normalizeGatewayUrl,
  parseHermesModelOptions,
  parseSkillNames,
  providerSlug,
  readSse,
  type GatewayPlace,
  type HermesModelOption,
  type ProbeResult,
} from "./gateway";

const FAIL = "No se ha podido conectar.";

const V4_BLOCK = [
  "0.0.0.0/8",
  "10.0.0.0/8",
  "100.64.0.0/10",
  "127.0.0.0/8",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.168.0.0/16",
  "198.18.0.0/15",
  "224.0.0.0/4",
  "240.0.0.0/4",
];

function ipv4ToInt(ip: string): number | null {
  const p = ip.split(".");
  if (p.length !== 4) return null;
  const n = p.map(Number);
  if (n.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) return null;
  return ((n[0] << 24) | (n[1] << 16) | (n[2] << 8) | n[3]) >>> 0;
}

function inCidr(ip: string, cidr: string): boolean {
  const [base, bitsStr] = cidr.split("/");
  const bits = Number(bitsStr);
  const a = ipv4ToInt(ip);
  const b = ipv4ToInt(base);
  if (a === null || b === null || Number.isNaN(bits)) return false;
  const mask = bits === 0 ? 0 : (~0 << (32 - bits)) >>> 0;
  return (a & mask) === (b & mask);
}

function isBlockedV6(ip: string): boolean {
  const n = ip.toLowerCase();
  if (n === "::" || n === "::1") return true;
  if (n.startsWith("fc") || n.startsWith("fd")) return true;
  if (n.startsWith("fe80")) return true;
  if (n.startsWith("ff")) return true;
  if (n.startsWith("::ffff:")) return isBlockedIp(n.slice(7));
  return false;
}

function isBlockedIp(ip: string): boolean {
  const ver = isIP(ip);
  if (ver === 4) return V4_BLOCK.some((c) => inCidr(ip, c));
  if (ver === 6) return isBlockedV6(ip);
  return true;
}

export async function assertPublicHermesUrl(raw: string): Promise<string> {
  const base = normalizeGatewayUrl(raw);
  const u = new URL(base);
  if (isPrivateHostname(u.hostname)) {
    throw new GatewayError("private", FAIL);
  }
  const host = u.hostname.replace(/^\[|\]$/g, "");
  if (isIP(host)) {
    if (isBlockedIp(host)) throw new GatewayError("private", FAIL);
    return base;
  }
  try {
    const recs = await lookup(host, { all: true });
    if (recs.length === 0) {
      throw new GatewayError("unreachable", FAIL);
    }
    for (const rec of recs) {
      if (isBlockedIp(rec.address)) throw new GatewayError("private", FAIL);
    }
  } catch (e) {
    if (e instanceof GatewayError) throw e;
    throw new GatewayError("unreachable", FAIL);
  }
  return base;
}

function hermesHeaders(key: string, extra?: Record<string, string>): HeadersInit {
  return {
    Authorization: `Bearer ${key}`,
    Accept: "application/json",
    ...extra,
  };
}

export type GateSecret = { k: string; u: string; p: GatewayPlace };

const COOKIE = "hg";

let ephemeralCookieKey: Buffer | null = null;

function cookieKey(): Buffer {
  const s = process.env.HERMES_COOKIE_SECRET?.trim();
  if (s) return createHash("sha256").update(s).digest();
  if (!ephemeralCookieKey) ephemeralCookieKey = randomBytes(32);
  return ephemeralCookieKey;
}

export function sealGate(data: GateSecret): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", cookieKey(), iv);
  const enc = Buffer.concat([cipher.update(JSON.stringify(data), "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, enc]).toString("base64url");
}

export function openGate(token: string): GateSecret | null {
  try {
    const buf = Buffer.from(token, "base64url");
    if (buf.length < 29) return null;
    const iv = buf.subarray(0, 12);
    const tag = buf.subarray(12, 28);
    const enc = buf.subarray(28);
    const decipher = createDecipheriv("aes-256-gcm", cookieKey(), iv);
    decipher.setAuthTag(tag);
    const json = Buffer.concat([decipher.update(enc), decipher.final()]).toString("utf8");
    const data = JSON.parse(json) as Partial<GateSecret>;
    if (typeof data.k !== "string" || typeof data.u !== "string") return null;
    if (data.p !== "cloud" && data.p !== "mac") data.p = "cloud";
    return { k: data.k, u: data.u, p: data.p ?? "cloud" };
  } catch {
    return null;
  }
}

export function readGateCookie(request: Request): GateSecret | null {
  const header = request.headers.get("cookie") || "";
  const parts = header.split(";");
  for (const part of parts) {
    const trimmed = part.trim();
    if (!trimmed.startsWith(`${COOKIE}=`)) continue;
    return openGate(decodeURIComponent(trimmed.slice(COOKIE.length + 1)));
  }
  return null;
}

export function gateSetCookie(value: string | null): string {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  if (!value) {
    return `${COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${secure}`;
  }
  return `${COOKIE}=${value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000${secure}`;
}

export async function probeHermes(url: string, key: string, signal?: AbortSignal): Promise<ProbeResult> {
  try {
    const base = await assertPublicHermesUrl(url);
    const token = assertGatewayKey(key);
    const ctrl = signal ?? AbortSignal.timeout(12_000);
    const headers = hermesHeaders(token);

    let modelsRes: Response;
    try {
      modelsRes = await fetch(`${base}/v1/models`, {
        headers,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
      });
    } catch (e) {
      if ((e as Error).name === "AbortError") {
        return { ok: false, code: "unreachable", error: FAIL };
      }
      return { ok: false, code: "unreachable", error: FAIL };
    }

    if (modelsRes.status >= 300 && modelsRes.status < 400) {
      return { ok: false, code: "not_hermes", error: FAIL };
    }
    if (modelsRes.status === 401 || modelsRes.status === 403) {
      return { ok: false, code: "unauthorized", error: "La clave no es correcta." };
    }
    if (!modelsRes.ok) {
      return { ok: false, code: "not_hermes", error: FAIL };
    }

    let model = "hermes-agent";
    let provider: string | undefined;
    let models: HermesModelOption[] = [];
    let platform: string | undefined;
    let skills: string[] | undefined;
    try {
      const body = await modelsRes.json();
      const parsed = parseHermesModelOptions(body);
      models = parsed.models;
      model = parsed.currentModel || modelFromList(body);
      provider = parsed.currentProvider;
    } catch {
      // keep default
    }

    try {
      const extra = await enrichWithModelOptions(base, token, ctrl, {
        models,
        currentModel: model,
        currentProvider: provider,
      });
      models = extra.models;
      if (extra.currentModel) model = extra.currentModel;
      if (extra.currentProvider) provider = extra.currentProvider;
    } catch {
      // optional
    }

    try {
      const cap = await fetch(`${base}/v1/capabilities`, {
        headers,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
      });
      if (cap.ok) {
        const body = (await cap.json()) as { platform?: unknown; model?: unknown };
        if (typeof body.platform === "string") platform = body.platform;
        if (typeof body.model === "string" && body.model) model = body.model;
      }
    } catch {
      // optional
    }

    try {
      const sk = await fetch(`${base}/v1/skills`, {
        headers,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
      });
      if (sk.ok) skills = parseSkillNames(await sk.json());
    } catch {
      // optional
    }

    return { ok: true, model, provider, models, platform, skills, mode: "proxy" };
  } catch (e) {
    if (e instanceof GatewayError) return { ok: false, code: e.code, error: FAIL };
    return { ok: false, code: "unreachable", error: FAIL };
  }
}

type ChatTurn = { role: "user" | "assistant"; content: string };

export async function listHermesModelsServer(
  url: string,
  key: string,
  signal?: AbortSignal,
  refresh = false,
): Promise<{ models: HermesModelOption[]; currentModel?: string; currentProvider?: string }> {
  const base = await assertPublicHermesUrl(url);
  const token = assertGatewayKey(key);
  const ctrl = signal ?? AbortSignal.timeout(20_000);
  let fallback: {
    models: HermesModelOption[];
    currentModel?: string;
    currentProvider?: string;
  } = { models: [] };
  try {
    const res = await fetch(`${base}/v1/models`, {
      headers: hermesHeaders(token),
      signal: ctrl,
      cache: "no-store",
      redirect: "manual",
    });
    if (res.ok) fallback = parseHermesModelOptions(await res.json());
  } catch (e) {
    if ((e as Error).name === "AbortError") throw e;
  }
  return enrichWithModelOptions(base, token, ctrl, fallback, refresh);
}

export async function setHermesModelServer(opts: {
  url: string;
  key: string;
  model: string;
  provider?: string;
  conversationId?: string;
  signal?: AbortSignal;
}): Promise<{ ok: boolean }> {
  const base = await assertPublicHermesUrl(opts.url);
  const token = assertGatewayKey(opts.key);
  const ctrl = opts.signal ?? AbortSignal.timeout(12_000);
  const provider = providerSlug(opts.provider || "");
  const headers = hermesHeaders(token, { "Content-Type": "application/json" });
  let ok = false;
  try {
    const setRes = await fetch(`${base}/api/model/set`, {
      method: "POST",
      headers,
      signal: ctrl,
      cache: "no-store",
      redirect: "manual",
      body: JSON.stringify({
        scope: "main",
        model: opts.model,
        provider,
      }),
    });
    ok = setRes.ok;
  } catch {
    // optional
  }
  const command = provider
    ? `/model ${opts.model} --provider ${provider} --global`
    : `/model ${opts.model} --global`;
  try {
    const chatRes = await fetch(`${base}/v1/chat/completions`, {
      method: "POST",
      headers: hermesHeaders(token, {
        "Content-Type": "application/json",
        ...(opts.conversationId
          ? { "X-Hermes-Session-Key": opts.conversationId.slice(0, 256) }
          : {}),
      }),
      signal: ctrl,
      cache: "no-store",
      redirect: "manual",
      body: JSON.stringify({
        model: opts.model,
        stream: false,
        messages: [{ role: "user", content: command }],
        ...(provider ? { provider } : {}),
      }),
    });
    ok = chatRes.ok || ok;
  } catch {
    // optional
  }
  return { ok };
}

export async function streamHermesProxy(opts: {
  url: string;
  key: string;
  messages: ChatTurn[];
  conversationId?: string;
  model?: string;
  provider?: string;
  signal: AbortSignal;
}): Promise<Response> {
  const base = await assertPublicHermesUrl(opts.url);
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);

  const upstream = await fetch(`${base}/v1/chat/completions`, {
    method: "POST",
    headers: hermesHeaders(token, {
      "Content-Type": "application/json",
      Accept: "text/event-stream",
      ...(opts.conversationId
        ? { "X-Hermes-Session-Key": opts.conversationId.slice(0, 256) }
        : {}),
    }),
    signal,
    cache: "no-store",
    redirect: "manual",
    body: JSON.stringify({
      model: opts.model || "hermes-agent",
      stream: true,
      messages: opts.messages,
      ...(opts.provider ? { provider: opts.provider } : {}),
    }),
  });

  if (upstream.status === 401 || upstream.status === 403) {
    return ndjsonResponse(async (send) => {
      send({ type: "error", message: "La clave no es correcta." });
    }, 401);
  }
  if (!upstream.ok || !upstream.body) {
    return ndjsonResponse(async (send) => {
      send({ type: "error", message: FAIL });
    }, upstream.status >= 400 ? upstream.status : 502);
  }

  return ndjsonResponse(async (send) => {
    for await (const chunk of readSse(upstream.body!)) {
      const ev = eventFromChunk(chunk);
      if (ev) send(ev);
    }
  });
}

export function ndjsonResponse(
  write: (send: (obj: unknown) => void) => Promise<void>,
  status = 200,
): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    async start(controller) {
      const send = (obj: unknown) => {
        controller.enqueue(encoder.encode(JSON.stringify(obj) + "\n"));
      };
      try {
        await write(send);
      } catch (e) {
        if ((e as Error).name !== "AbortError") {
          send({ type: "error", message: FAIL });
        }
      } finally {
        controller.close();
      }
    },
  });
  return new Response(stream, {
    status,
    headers: {
      "Content-Type": "application/x-ndjson; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

export function jsonWithCookie(body: unknown, status: number, cookie?: string | null) {
  const headers = new Headers({
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  if (cookie !== undefined) headers.append("Set-Cookie", gateSetCookie(cookie));
  return new Response(JSON.stringify(body), { status, headers });
}
