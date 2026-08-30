import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from "node:crypto";
import { execFile } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import {
  assertPublicHttpUrl,
  localPrivateNetworkEnabled,
  pinnedFetch as fetch,
  UnsafeOutboundUrlError,
} from "./outbound-http.server";
import {
  assertGatewayKey,
  enrichWithModelOptions,
  eventFromChunk,
  GatewayError,
  HERMES_NOTES_CHAR_LIMIT,
  HERMES_USER_CHAR_LIMIT,
  isPrivateHostname,
  modelFromList,
  normalizeGatewayUrl,
  parseHermesModelOptions,
  parseSkillNames,
  prettyProvider,
  providerSlug,
  normalizeLlmBaseUrl,
  readSse,
  unionHermesModels,
  type GatewayPlace,
  type HermesMemoryProfile,
  type HermesMemoryResult,
  type HermesMemoryStore,
  type HermesModelOption,
  type HermesChatContent,
  type ProbeResult,
} from "./gateway";
import {
  parseHermesCapabilityManifest,
  type HermesCapabilityManifest,
} from "./gateway-contracts";

const execFileAsync = promisify(execFile);

const FAIL = "Couldn’t connect.";

export async function assertPublicHermesUrl(raw: string): Promise<string> {
  const base = normalizeGatewayUrl(raw);
  const u = new URL(base);
  if (isPrivateHostname(u.hostname)) {
    throw new GatewayError("private", FAIL);
  }
  try {
    await assertPublicHttpUrl(base);
  } catch (e) {
    if (e instanceof UnsafeOutboundUrlError) {
      throw new GatewayError(
        e.reason === "private" ? "private" : "unreachable",
        FAIL,
      );
    }
    throw new GatewayError("unreachable", FAIL);
  }
  return base;
}

export async function resolveHermesBase(
  raw: string,
  place?: GatewayPlace,
): Promise<string> {
  if (place === "mac" && localPrivateNetworkEnabled()) {
    return normalizeGatewayUrl(raw);
  }
  return assertPublicHermesUrl(raw);
}

function hermesHeaders(
  key: string,
  extra?: Record<string, string>,
): HeadersInit {
  return {
    Authorization: `Bearer ${key}`,
    "X-Hermes-Session-Token": key,
    Accept: "application/json",
    ...extra,
  };
}

export type StoredEndpoint = {
  n: string;
  s: string;
  u: string;
  k: string;
  m: string;
  ms?: string[];
  d?: boolean;
};

export type GateSecret = {
  k: string;
  u: string;
  p: GatewayPlace;
  ep?: StoredEndpoint[];
  uid?: string;
};

const COOKIE = "hg";

let ephemeralCookieKey: Buffer | null = null;

type GateKey = { id: string; key: Buffer };

function gateKeys(): GateKey[] {
  const configured = (process.env.HERMES_COOKIE_KEYS ?? "")
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .flatMap((entry) => {
      const separator = entry.indexOf(":");
      if (separator <= 0) return [];
      const id = entry.slice(0, separator).trim();
      const secret = entry.slice(separator + 1).trim();
      return id && secret
        ? [{ id, key: createHash("sha256").update(secret).digest() }]
        : [];
    });
  if (configured.length) return configured;

  const secret =
    process.env.HERMES_COOKIE_SECRET?.trim() ||
    process.env.BETTER_AUTH_SECRET?.trim();
  if (secret) {
    return [
      { id: "primary", key: createHash("sha256").update(secret).digest() },
    ];
  }
  if (process.env.NODE_ENV === "production") {
    throw new Error("Persistent Hermes credential encryption key is missing");
  }
  if (!ephemeralCookieKey) ephemeralCookieKey = randomBytes(32);
  return [{ id: "development", key: ephemeralCookieKey }];
}

export function sealGate(data: GateSecret): string {
  const active = gateKeys()[0];
  if (!active) throw new Error("Hermes credential keyring is empty");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", active.key, iv);
  const enc = Buffer.concat([
    cipher.update(JSON.stringify(data), "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  const payload = Buffer.concat([iv, tag, enc]).toString("base64url");
  return `v1.${active.id}.${payload}`;
}

export function openGate(token: string): GateSecret | null {
  const keys = gateKeys();
  const parts = token.split(".");
  const versioned = parts.length === 3 && parts[0] === "v1";
  const payload = versioned ? parts[2] : token;
  const candidates = versioned
    ? keys.filter((item) => item.id === parts[1])
    : keys;
  if (!payload || candidates.length === 0) return null;
  for (const candidate of candidates) {
    const data = decryptGate(payload, candidate.key);
    if (data) return data;
  }
  return null;
}

function decryptGate(token: string, key: Buffer): GateSecret | null {
  try {
    const buf = Buffer.from(token, "base64url");
    if (buf.length < 29) return null;
    const iv = buf.subarray(0, 12);
    const tag = buf.subarray(12, 28);
    const enc = buf.subarray(28);
    const decipher = createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAuthTag(tag);
    const json = Buffer.concat([
      decipher.update(enc),
      decipher.final(),
    ]).toString("utf8");
    const data = JSON.parse(json) as Partial<GateSecret>;
    if (typeof data.k !== "string" || typeof data.u !== "string") return null;
    if (data.p !== "cloud" && data.p !== "mac" && data.p !== "device") {
      data.p = "cloud";
    }
    const ep = parseStoredEndpoints(data.ep);
    const uid =
      typeof data.uid === "string" && data.uid.trim()
        ? data.uid.trim()
        : undefined;
    return {
      k: data.k,
      u: data.u,
      p: data.p ?? "cloud",
      ...(ep.length ? { ep } : {}),
      ...(uid ? { uid } : {}),
    };
  } catch {
    return null;
  }
}

function parseStoredEndpoints(raw: unknown): StoredEndpoint[] {
  if (!Array.isArray(raw)) return [];
  const out: StoredEndpoint[] = [];
  for (const item of raw) {
    const rec = asObj(item);
    const n = typeof rec.n === "string" ? rec.n.trim().slice(0, 64) : "";
    const s = typeof rec.s === "string" ? rec.s.trim().slice(0, 64) : "";
    const u = typeof rec.u === "string" ? rec.u.trim().slice(0, 512) : "";
    const k = typeof rec.k === "string" ? rec.k.slice(0, 256) : "";
    const m = typeof rec.m === "string" ? rec.m.trim().slice(0, 128) : "";
    if (!s || !u || !m) continue;
    const ms = idsFromUnknown(rec.ms).slice(0, 32);
    out.push({
      n: n || s,
      s,
      u,
      k,
      m,
      ...(ms.length ? { ms } : {}),
      d: rec.d === true,
    });
    if (out.length >= 8) break;
  }
  return out;
}

export function upsertStoredEndpoint(
  list: StoredEndpoint[] | undefined,
  next: StoredEndpoint,
): StoredEndpoint[] {
  const current = list ? [...list] : [];
  const idx = current.findIndex(
    (item) => item.s === next.s || item.u === next.u,
  );
  if (idx >= 0) current[idx] = next;
  else current.push(next);
  return current.slice(-8);
}

export function modelsFromEndpoints(
  list: StoredEndpoint[] | undefined,
): HermesModelOption[] {
  if (!list?.length) return [];
  const models: HermesModelOption[] = [];
  const seen = new Set<string>();
  for (const item of list) {
    const ids = [item.m, ...(item.ms || [])].filter(Boolean);
    for (const id of ids) {
      const key = `${item.s}:${id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      models.push({ id, label: id, provider: item.s, providerName: item.n });
    }
  }
  return models;
}

export function matchStoredEndpoint(
  list: StoredEndpoint[] | undefined,
  model?: string,
  provider?: string,
): StoredEndpoint | null {
  if (!list?.length) return null;
  const p = (provider || "").trim();
  const m = (model || "").trim();
  if (p) {
    return list.find((item) => item.s === p) ?? null;
  }
  if (m) {
    const byModel = list.find((item) => item.m === m || item.ms?.includes(m));
    if (byModel) return byModel;
  }
  return null;
}

function mergeModelLists(
  base: HermesModelOption[],
  extra: HermesModelOption[],
): HermesModelOption[] {
  const seen = new Set(base.map((item) => `${item.provider}:${item.id}`));
  const out = [...base];
  for (const item of extra) {
    const key = `${item.provider}:${item.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }
  return out;
}

async function probeOpenAiModels(
  llm: string,
  apiKey: string,
  signal: AbortSignal,
): Promise<string[]> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;
  const res = await fetch(`${llm}/models`, {
    headers,
    signal,
    cache: "no-store",
    redirect: "manual",
  });
  if (!res.ok) return [];
  try {
    const body = await res.json();
    const rec = asObj(body);
    return idsFromUnknown(rec.data ?? rec.models ?? body);
  } catch {
    return [];
  }
}

export function readGateCookie(
  request: Request,
  scope?: { userId: string | null; owner: boolean },
): GateSecret | null {
  const header = request.headers.get("cookie") || "";
  const parts = header.split(";");
  let data: GateSecret | null = null;
  for (const part of parts) {
    const trimmed = part.trim();
    if (!trimmed.startsWith(`${COOKIE}=`)) continue;
    data = openGate(decodeURIComponent(trimmed.slice(COOKIE.length + 1)));
    break;
  }
  if (!data) return null;
  if (!scope) return data;
  if (data.uid) {
    if (!scope.userId || data.uid !== scope.userId) return null;
    return data;
  }
  return null;
}

async function loadStoredGate(userId: string): Promise<GateSecret | null> {
  try {
    const { getSql } = await import("@/lib/db");
    const sql = await getSql();
    const rows = await sql.query<{ token: string }>(
      `select token from hermes_gate where user_id = $1 limit 1`,
      [userId],
    );
    const token = rows[0]?.token;
    return token ? openGate(token) : null;
  } catch {
    return null;
  }
}

export async function persistUserGate(
  userId: string | null,
  token: string | null,
) {
  if (!userId) return;
  try {
    const { getSql } = await import("@/lib/db");
    const sql = await getSql();
    if (!token) {
      await sql.query(`delete from hermes_gate where user_id = $1`, [userId]);
      return;
    }
    await sql.query(
      `insert into hermes_gate (user_id, token, updated_at)
       values ($1, $2, now())
       on conflict (user_id) do update set token = excluded.token, updated_at = now()`,
      [userId, token],
    );
  } catch {
    // Cookie still carries the session when the table is unavailable.
  }
}

export async function resolveAliceGate(request: Request): Promise<{
  saved: GateSecret | null;
  owner: boolean;
  local: boolean;
  userId: string | null;
  email: string | null;
}> {
  const { getSessionUser } = await import("@/lib/auth/verify.server");
  const { isLocalHermesOwner, localHermesAvailable } =
    await import("@/lib/auth/owner.server");
  const user = await getSessionUser();
  const owner = await isLocalHermesOwner(user?.id ?? null, user?.email);
  const local = localHermesAvailable();
  const fromCookie = readGateCookie(request, {
    userId: user?.id ?? null,
    owner,
  });
  const saved = fromCookie ?? (user?.id ? await loadStoredGate(user.id) : null);
  return {
    saved,
    owner,
    local,
    userId: user?.id ?? null,
    email: user?.email ?? null,
  };
}

export function gateSetCookie(value: string | null): string {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  if (!value) {
    return `${COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0${secure}`;
  }
  return `${COOKIE}=${value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000${secure}`;
}

export async function probeHermes(
  url: string,
  key: string,
  signal?: AbortSignal,
  place?: GatewayPlace,
): Promise<ProbeResult> {
  try {
    const base = await resolveHermesBase(url, place);
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
      return {
        ok: false,
        code: "unauthorized",
        error: "The key is not correct.",
      };
    }
    if (!modelsRes.ok) {
      return { ok: false, code: "not_hermes", error: FAIL };
    }

    let model = "hermes-agent";
    let provider: string | undefined;
    let models: HermesModelOption[] = [];
    let platform: string | undefined;
    let skills: string[] | undefined;
    let manifest: HermesCapabilityManifest | undefined;
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
        const body = (await cap.json()) as Record<string, unknown>;
        manifest = parseHermesCapabilityManifest(body);
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

    const fromDisk = await modelsFromLocalHermesHome();
    models = unionHermesModels(fromDisk, models);

    return {
      ok: true,
      model,
      provider,
      models,
      platform,
      skills,
      manifest,
      mode: "proxy",
    };
  } catch (e) {
    if (e instanceof GatewayError)
      return { ok: false, code: e.code, error: FAIL };
    return { ok: false, code: "unreachable", error: FAIL };
  }
}

type ChatTurn = { role: "user" | "assistant"; content: HermesChatContent };

export async function listHermesModelsServer(
  url: string,
  key: string,
  signal?: AbortSignal,
  refresh = false,
  place?: GatewayPlace,
): Promise<{
  models: HermesModelOption[];
  currentModel?: string;
  currentProvider?: string;
}> {
  const base = await resolveHermesBase(url, place);
  const token = assertGatewayKey(key);
  const ctrl = signal ?? AbortSignal.timeout(20_000);
  let acc: {
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
    if (res.ok) acc = parseHermesModelOptions(await res.json());
  } catch (e) {
    if ((e as Error).name === "AbortError") throw e;
  }
  for (const apiBase of managementBases(base, place)) {
    try {
      acc = await enrichWithModelOptions(apiBase, token, ctrl, acc, refresh);
    } catch (e) {
      if ((e as Error).name === "AbortError") throw e;
    }
    try {
      const fromCfg = await modelsFromHermesConfigApi(apiBase, token, ctrl);
      if (fromCfg.length)
        acc = { ...acc, models: unionHermesModels(acc.models, fromCfg) };
    } catch (e) {
      if ((e as Error).name === "AbortError") throw e;
    }
  }
  const fromDisk = await modelsFromLocalHermesHome();
  return {
    ...acc,
    models: unionHermesModels(fromDisk, acc.models),
  };
}

async function modelsFromHermesConfigApi(
  apiBase: string,
  token: string,
  signal: AbortSignal,
): Promise<HermesModelOption[]> {
  const res = await fetch(`${apiBase}/api/config`, {
    headers: hermesHeaders(token),
    signal,
    cache: "no-store",
    redirect: "manual",
  });
  if (!res.ok) return [];
  const raw = await hermesJson(res);
  const cfg =
    raw &&
    (raw.model !== undefined ||
      raw.fallback_providers !== undefined ||
      raw.providers !== undefined)
      ? raw
      : asObj(raw?.config);
  return modelsFromConfigDoc(cfg);
}

function modelsFromConfigDoc(
  cfg: Record<string, unknown>,
): HermesModelOption[] {
  const out: HermesModelOption[] = [];
  const seen = new Set<string>();
  const push = (id: string, provider: string, providerName?: string) => {
    const model = id.trim();
    const slug = (provider || "").trim();
    if (!model) return;
    const key = `${slug}:${model}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.push({
      id: model,
      label: model,
      provider: slug,
      providerName: providerName || (slug ? prettyProvider(slug) : undefined),
    });
  };
  const model = asObj(cfg.model);
  if (typeof cfg.model === "string") push(cfg.model, "");
  else {
    const id =
      typeof model.default === "string"
        ? model.default
        : typeof model.name === "string"
          ? model.name
          : "";
    const provider = typeof model.provider === "string" ? model.provider : "";
    push(id, provider);
  }
  const fallbacks = Array.isArray(cfg.fallback_providers)
    ? cfg.fallback_providers
    : [];
  for (const item of fallbacks) {
    const rec = asObj(item);
    push(
      typeof rec.model === "string" ? rec.model : "",
      typeof rec.provider === "string" ? rec.provider : "",
    );
  }
  const providers = asObj(cfg.providers);
  for (const [slug, raw] of Object.entries(providers)) {
    const rec = asObj(raw);
    const name = typeof rec.name === "string" ? rec.name : prettyProvider(slug);
    const one =
      typeof rec.model === "string"
        ? rec.model
        : typeof rec.default === "string"
          ? rec.default
          : "";
    push(one, slug, name);
    for (const id of idsFromUnknown(rec.models)) push(id, slug, name);
  }
  return out;
}

async function modelsFromLocalHermesHome(): Promise<HermesModelOption[]> {
  const file = `${process.env.HERMES_HOME?.trim() || `${homedir()}/.hermes`}/config.yaml`;
  const script = `import json,sys,yaml
cfg=yaml.safe_load(open(sys.argv[1],encoding="utf-8")) or {}
def scrub(o):
  if isinstance(o, dict):
    return {k:scrub(v) for k,v in o.items() if k not in ("api_key","api","key","key_env")}
  if isinstance(o, list):
    return [scrub(x) for x in o]
  return o
print(json.dumps(scrub(cfg)))`;
  try {
    const { stdout } = await execFileAsync("python3", ["-c", script, file], {
      timeout: 5000,
    });
    const cfg = JSON.parse(stdout) as Record<string, unknown>;
    return modelsFromConfigDoc(asObj(cfg));
  } catch {
    return [];
  }
}

function hermesHomeDir() {
  return process.env.HERMES_HOME?.trim() || join(homedir(), ".hermes");
}

function splitMemoryEntries(raw: string): string[] {
  const text = raw.replace(/^\uFEFF/, "").trim();
  if (!text) return [];
  if (text.includes("§"))
    return text
      .split(/\s*§\s*/)
      .map((s) => s.trim())
      .filter(Boolean);
  return text
    .split(/\n{2,}/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function memoryStore(raw: string, limit: number): HermesMemoryStore {
  const text = raw.replace(/^\uFEFF/, "").trim();
  return {
    raw: text,
    entries: splitMemoryEntries(text),
    chars: text.length,
    limit,
  };
}

async function readUtf8(path: string): Promise<string> {
  try {
    return await readFile(path, "utf8");
  } catch {
    return "";
  }
}

async function localHermesProfiles(): Promise<
  Array<{ name: string; dir: string }>
> {
  const home = hermesHomeDir();
  const out: Array<{ name: string; dir: string }> = [
    { name: "default", dir: home },
  ];
  try {
    const entries = await readdir(join(home, "profiles"), {
      withFileTypes: true,
    });
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      out.push({ name: entry.name, dir: join(home, "profiles", entry.name) });
    }
  } catch {
    // no extra profiles
  }
  return out;
}

async function profileFromDir(
  name: string,
  dir: string,
): Promise<HermesMemoryProfile> {
  const [soul, user, notes] = await Promise.all([
    readUtf8(join(dir, "SOUL.md")),
    readUtf8(join(dir, "memories", "USER.md")),
    readUtf8(join(dir, "memories", "MEMORY.md")),
  ]);
  return {
    name,
    soul: soul.replace(/^\uFEFF/, "").trim(),
    user: memoryStore(user, HERMES_USER_CHAR_LIMIT),
    notes: memoryStore(notes, HERMES_NOTES_CHAR_LIMIT),
  };
}

export async function fetchHermesMemory(opts?: {
  url?: string;
  key?: string;
  place?: GatewayPlace;
  signal?: AbortSignal;
  local?: boolean;
}): Promise<HermesMemoryResult> {
  const locals = opts?.local === false ? [] : await localHermesProfiles();
  const profiles = await Promise.all(
    locals.map((p) => profileFromDir(p.name, p.dir)),
  );
  let active = "default";

  if (opts?.url && opts.key) {
    try {
      const base = await resolveHermesBase(opts.url, opts.place);
      const token = assertGatewayKey(opts.key);
      const ctrl = opts.signal ?? AbortSignal.timeout(12_000);
      const headers = hermesHeaders(token);
      for (const apiBase of managementBases(base, opts.place)) {
        try {
          const activeRes = await fetch(`${apiBase}/api/profiles/active`, {
            headers,
            signal: ctrl,
            cache: "no-store",
            redirect: "manual",
          });
          if (activeRes.ok) {
            const body = asObj(await hermesJson(activeRes));
            const name =
              (typeof body.current === "string" && body.current.trim()) ||
              (typeof body.active === "string" && body.active.trim()) ||
              "";
            if (name) active = name;
          }
        } catch (e) {
          if ((e as Error).name === "AbortError") throw e;
        }
        for (const profile of profiles) {
          if (profile.soul) continue;
          try {
            const soulRes = await fetch(
              `${apiBase}/api/profiles/${encodeURIComponent(profile.name)}/soul`,
              { headers, signal: ctrl, cache: "no-store", redirect: "manual" },
            );
            if (!soulRes.ok) continue;
            const body = asObj(await hermesJson(soulRes));
            if (typeof body.content === "string" && body.content.trim()) {
              profile.soul = body.content.trim();
            }
          } catch (e) {
            if ((e as Error).name === "AbortError") throw e;
          }
        }
      }
    } catch {
      // local files are enough
    }
  }

  if (!profiles.some((p) => p.name === active) && profiles[0])
    active = profiles[0].name;
  return {
    ok: true,
    active,
    profiles: profiles.map((p) => ({ ...p, current: p.name === active })),
  };
}

export async function setHermesModelServer(opts: {
  url: string;
  key: string;
  model: string;
  provider?: string;
  conversationId?: string;
  signal?: AbortSignal;
  place?: GatewayPlace;
}): Promise<{ ok: boolean }> {
  const base = await resolveHermesBase(opts.url, opts.place);
  const token = assertGatewayKey(opts.key);
  const ctrl = opts.signal ?? AbortSignal.timeout(12_000);
  const provider =
    (opts.provider || "").trim() || providerSlug(opts.provider || "");
  const headers = hermesHeaders(token, { "Content-Type": "application/json" });
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
    if (setRes.ok) return { ok: true };
  } catch {
    // fall through to /model
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
    return { ok: chatRes.ok };
  } catch {
    return { ok: false };
  }
}

async function hermesJson(
  res: Response,
): Promise<Record<string, unknown> | null> {
  try {
    const body = await res.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? (body as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function hermesDetail(
  body: Record<string, unknown> | null,
  fallback = FAIL,
): string {
  if (!body) return fallback;
  if (typeof body.detail === "string" && body.detail.trim())
    return body.detail.trim();
  if (Array.isArray(body.detail)) {
    const parts = body.detail
      .map((item) => {
        if (typeof item === "string") return item;
        if (item && typeof item === "object" && !Array.isArray(item)) {
          const rec = item as Record<string, unknown>;
          if (typeof rec.msg === "string") return rec.msg;
        }
        return "";
      })
      .filter(Boolean);
    if (parts.length) return parts.join(" ");
  }
  if (typeof body.message === "string" && body.message.trim())
    return body.message.trim();
  if (typeof body.error === "string" && body.error.trim())
    return body.error.trim();
  return fallback;
}

function friendlyHermesSaveError(
  status: number,
  body: Record<string, unknown> | null,
): string {
  if (status === 401 || status === 403) return "The key is not correct.";
  if (status === 409)
    return "That endpoint is already in Hermes. Check the chat picker.";
  const detail = hermesDetail(body, "");
  if (detail && !/^not found$/i.test(detail)) return detail;
  if (status === 404 || status === 405) {
    return "This Hermes has no settings panel at that address. If chat uses another port, try the dashboard (often 9119).";
  }
  return "Hermes couldn’t save the endpoint.";
}

function isMissingRoute(status: number): boolean {
  return status === 404 || status === 405;
}

function asObj(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function managementBases(base: string, place?: GatewayPlace): string[] {
  const out = [base];
  if (place !== "mac") return out;
  try {
    const u = new URL(base);
    if (u.port === "9119") return out;
    const dash = `${u.protocol}//${u.hostname}:9119`;
    if (!out.includes(dash)) out.push(dash);
  } catch {
    // keep the connected URL only
  }
  return out;
}

export function getHermesHomeDir() {
  return hermesHomeDir();
}

export async function hermesDashboardGet(
  opts: {
    url: string;
    key: string;
    place?: GatewayPlace;
    signal?: AbortSignal;
  },
  path: string,
): Promise<unknown> {
  const base = await resolveHermesBase(opts.url, opts.place);
  const token = assertGatewayKey(opts.key);
  const ctrl = opts.signal ?? AbortSignal.timeout(12_000);
  const headers = hermesHeaders(token);
  for (const apiBase of managementBases(base, opts.place)) {
    try {
      const res = await fetch(`${apiBase}${path}`, {
        headers,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
      });
      if (!res.ok) continue;
      const text = await res.text();
      if (!text.trim()) continue;
      try {
        return JSON.parse(text) as unknown;
      } catch {
        continue;
      }
    } catch (e) {
      if ((e as Error).name === "AbortError") throw e;
    }
  }
  return null;
}

export async function hermesDashboardSend(
  opts: {
    url: string;
    key: string;
    place?: GatewayPlace;
    signal?: AbortSignal;
  },
  path: string,
  method: string,
  body?: unknown,
): Promise<boolean> {
  const base = await resolveHermesBase(opts.url, opts.place);
  const token = assertGatewayKey(opts.key);
  const ctrl = opts.signal ?? AbortSignal.timeout(12_000);
  const headers = hermesHeaders(token, { "Content-Type": "application/json" });
  for (const apiBase of managementBases(base, opts.place)) {
    try {
      const res = await fetch(`${apiBase}${path}`, {
        method,
        headers,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      if (res.ok) return true;
    } catch (e) {
      if ((e as Error).name === "AbortError") throw e;
    }
  }
  return false;
}

function idsFromUnknown(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const ids: string[] = [];
  for (const item of value) {
    if (typeof item === "string" && item.trim()) ids.push(item.trim());
    else if (item && typeof item === "object" && !Array.isArray(item)) {
      const rec = item as Record<string, unknown>;
      const id =
        typeof rec.id === "string"
          ? rec.id
          : typeof rec.model === "string"
            ? rec.model
            : "";
      if (id.trim()) ids.push(id.trim());
    }
  }
  return ids;
}

type SaveAttempt =
  | { kind: "ok"; provider: string }
  | { kind: "auth" }
  | { kind: "abort" }
  | { kind: "down" }
  | { kind: "missing" }
  | { kind: "error"; error: string };

async function hermesPost(
  url: string,
  headers: HeadersInit,
  signal: AbortSignal,
  body: unknown,
): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers,
    signal,
    cache: "no-store",
    redirect: "manual",
    body: JSON.stringify(body),
  });
}

async function saveViaCustomEndpoints(
  apiBase: string,
  headers: HeadersInit,
  ctrl: AbortSignal,
  payload: unknown,
): Promise<SaveAttempt> {
  try {
    const save = await hermesPost(
      `${apiBase}/api/providers/custom-endpoints`,
      headers,
      ctrl,
      payload,
    );
    if (save.status === 401 || save.status === 403) return { kind: "auth" };
    if (save.status === 409) return { kind: "ok", provider: "custom" };
    if (isMissingRoute(save.status) || save.status === 422)
      return { kind: "missing" };
    if (!save.ok)
      return {
        kind: "error",
        error: friendlyHermesSaveError(save.status, await hermesJson(save)),
      };
    return { kind: "ok", provider: "custom" };
  } catch (e) {
    if ((e as Error).name === "AbortError") return { kind: "abort" };
    return { kind: "down" };
  }
}

async function saveViaModelSet(
  apiBase: string,
  headers: HeadersInit,
  ctrl: AbortSignal,
  model: string,
  llm: string,
  apiKey: string,
): Promise<SaveAttempt> {
  const assignBody = {
    scope: "main" as const,
    provider: "custom",
    model,
    base_url: llm,
    api_key: apiKey,
  };
  try {
    let setRes = await hermesPost(
      `${apiBase}/api/model/set`,
      headers,
      ctrl,
      assignBody,
    );
    let setJson = await hermesJson(setRes);
    if (setJson?.confirm_required === true) {
      setRes = await hermesPost(`${apiBase}/api/model/set`, headers, ctrl, {
        ...assignBody,
        confirm_expensive_model: true,
      });
      setJson = await hermesJson(setRes);
    }
    if (setRes.status === 401 || setRes.status === 403) return { kind: "auth" };
    if (isMissingRoute(setRes.status) || setRes.status === 422)
      return { kind: "missing" };
    if (!setRes.ok && setJson?.ok !== true) {
      return {
        kind: "error",
        error: friendlyHermesSaveError(setRes.status, setJson),
      };
    }
    return { kind: "ok", provider: "custom" };
  } catch (e) {
    if ((e as Error).name === "AbortError") return { kind: "abort" };
    return { kind: "down" };
  }
}

async function saveViaConfig(
  apiBase: string,
  headers: HeadersInit,
  ctrl: AbortSignal,
  opts: {
    name: string;
    slug: string;
    llm: string;
    apiKey: string;
    model: string;
    models: string[];
  },
): Promise<SaveAttempt> {
  try {
    const get = await fetch(`${apiBase}/api/config`, {
      headers,
      signal: ctrl,
      cache: "no-store",
      redirect: "manual",
    });
    if (get.status === 401 || get.status === 403) return { kind: "auth" };
    if (isMissingRoute(get.status)) return { kind: "missing" };
    if (!get.ok)
      return {
        kind: "error",
        error: friendlyHermesSaveError(get.status, await hermesJson(get)),
      };

    const currentRaw = await hermesJson(get);
    const current =
      currentRaw &&
      (currentRaw.model !== undefined ||
        currentRaw.providers !== undefined ||
        currentRaw.custom_providers !== undefined)
        ? currentRaw
        : asObj(currentRaw?.config);
    const providers = asObj(current?.providers);
    const existing = asObj(providers[opts.slug]);
    providers[opts.slug] = {
      ...existing,
      name: opts.name,
      api: opts.llm,
      base_url: opts.llm,
      model: opts.model,
      models: opts.models,
      discover_models: true,
      ...(opts.apiKey ? { api_key: opts.apiKey } : {}),
    };

    const legacy = Array.isArray(current?.custom_providers)
      ? [...current.custom_providers]
      : [];
    const entry = {
      name: opts.name,
      base_url: opts.llm,
      model: opts.model,
      models: opts.models,
      ...(opts.apiKey ? { api_key: opts.apiKey } : {}),
    };
    const idx = legacy.findIndex((item) => {
      const rec = asObj(item);
      return (
        rec.name === opts.name ||
        rec.base_url === opts.llm ||
        rec.api === opts.llm
      );
    });
    if (idx >= 0) legacy[idx] = { ...asObj(legacy[idx]), ...entry };
    else legacy.push(entry);

    const prevModel = asObj(current?.model);
    const modelBlock = {
      ...prevModel,
      provider: "custom",
      default: opts.model,
      base_url: opts.llm,
      api_mode: "chat_completions",
      ...(opts.apiKey ? { api_key: opts.apiKey } : {}),
    };
    const bodies = [
      { config: { model: modelBlock, providers, custom_providers: legacy } },
      { config: { model: modelBlock, providers } },
      { config: { model: modelBlock } },
    ];
    for (const body of bodies) {
      const put = await fetch(`${apiBase}/api/config`, {
        method: "PUT",
        headers,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
        body: JSON.stringify(body),
      });
      if (put.status === 401 || put.status === 403) return { kind: "auth" };
      if (put.ok) return { kind: "ok", provider: "custom" };
      if (isMissingRoute(put.status)) return { kind: "missing" };
      if (put.status === 422) continue;
      return {
        kind: "error",
        error: friendlyHermesSaveError(put.status, await hermesJson(put)),
      };
    }
    return { kind: "missing" };
  } catch (e) {
    if ((e as Error).name === "AbortError") return { kind: "abort" };
    return { kind: "down" };
  }
}

export async function saveHermesCustomEndpointServer(opts: {
  url: string;
  key: string;
  name: string;
  baseUrl: string;
  apiKey: string;
  model?: string;
  signal?: AbortSignal;
  place?: GatewayPlace;
}): Promise<{
  ok: boolean;
  error?: string;
  model?: string;
  provider?: string;
  models?: HermesModelOption[];
  persist?: StoredEndpoint;
}> {
  const base = await resolveHermesBase(opts.url, opts.place);
  const token = assertGatewayKey(opts.key);
  const llm = normalizeLlmBaseUrl(opts.baseUrl);
  try {
    if (opts.place !== "mac" && isPrivateHostname(new URL(llm).hostname)) {
      return {
        ok: false,
        error: "That endpoint is local. Choose “On this Mac”.",
      };
    }
  } catch {
    return { ok: false, error: "Check the address." };
  }
  const apiKey = opts.apiKey.trim();
  if (apiKey.length > 256) {
    return { ok: false, error: "The endpoint key is not correct." };
  }
  let name = opts.name.trim();
  if (!name) {
    try {
      name = new URL(llm).hostname.replace(/^www\./, "");
    } catch {
      name = "custom";
    }
  }
  const slug = providerSlug(name) || "custom";
  const ctrl = opts.signal ?? AbortSignal.timeout(20_000);
  const headers = hermesHeaders(token, { "Content-Type": "application/json" });
  let discovered: string[] = [];
  try {
    discovered = await probeOpenAiModels(llm, apiKey, ctrl);
  } catch (e) {
    if ((e as Error).name === "AbortError") {
      return { ok: false, error: "The model didn’t respond in time." };
    }
  }

  for (const apiBase of managementBases(base, opts.place)) {
    try {
      const probe = await hermesPost(
        `${apiBase}/api/providers/custom-endpoints/validate`,
        headers,
        ctrl,
        {
          name,
          base_url: llm,
          api_key: apiKey || null,
          model: opts.model || "auto",
        },
      );
      if (probe.status === 401 || probe.status === 403) {
        continue;
      }
      if (probe.ok) {
        const body = await hermesJson(probe);
        discovered = idsFromUnknown(body?.models);
        break;
      }
      if (!isMissingRoute(probe.status)) break;
    } catch (e) {
      if ((e as Error).name === "AbortError") {
        return { ok: false, error: "The model didn’t respond in time." };
      }
    }
    if (discovered.length) break;
    try {
      const alt = await hermesPost(
        `${apiBase}/api/providers/validate`,
        headers,
        ctrl,
        {
          key: "OPENAI_BASE_URL",
          value: llm,
          api_key: apiKey,
        },
      );
      if (alt.status === 401 || alt.status === 403) {
        continue;
      }
      if (alt.ok) {
        const body = await hermesJson(alt);
        discovered = idsFromUnknown(body?.models);
        break;
      }
    } catch (e) {
      if ((e as Error).name === "AbortError") {
        return { ok: false, error: "The model didn’t respond in time." };
      }
    }
  }

  const model = (opts.model || "").trim() || discovered[0] || "";
  if (!model) {
    return {
      ok: false,
      error:
        "That endpoint listed no models. Type one, for example glm-5.3-flash.",
    };
  }
  const models = discovered.length ? discovered : [model];
  const endpointPayloads: unknown[] = [
    {
      name,
      base_url: llm,
      api_key: apiKey || null,
      model,
      models,
      discover_models: true,
      make_default: true,
    },
    {
      name,
      base_url: llm,
      api_key: apiKey || null,
      model,
      make_default: true,
    },
  ];

  for (const apiBase of managementBases(base, opts.place)) {
    const attempts: SaveAttempt[] = [];
    for (const payload of endpointPayloads) {
      const result = await saveViaCustomEndpoints(
        apiBase,
        headers,
        ctrl,
        payload,
      );
      attempts.push(result);
      if (
        result.kind === "ok" ||
        result.kind === "auth" ||
        result.kind === "abort" ||
        result.kind === "error"
      ) {
        break;
      }
    }
    const terminal = () =>
      attempts.find(
        (result) =>
          result.kind === "ok" ||
          result.kind === "auth" ||
          result.kind === "abort" ||
          result.kind === "error",
      );
    if (!terminal())
      attempts.push(
        await saveViaModelSet(apiBase, headers, ctrl, model, llm, apiKey),
      );
    if (!terminal()) {
      attempts.push(
        await saveViaConfig(apiBase, headers, ctrl, {
          name,
          slug,
          llm,
          apiKey,
          model,
          models,
        }),
      );
    }
    const saved =
      terminal() ??
      (attempts.some((result) => result.kind === "missing")
        ? ({ kind: "missing" } as SaveAttempt)
        : (attempts.at(-1) ?? ({ kind: "missing" } as SaveAttempt)));
    if (saved.kind === "ok") {
      const extra = await enrichWithModelOptions(
        apiBase,
        token,
        ctrl,
        {
          models: [],
          currentModel: model,
          currentProvider: saved.provider || slug || "custom",
        },
        true,
      );
      const persist: StoredEndpoint = {
        n: name,
        s: slug,
        u: llm,
        k: apiKey,
        m: extra.currentModel || model,
        ms: models,
        d: false,
      };
      return {
        ok: true,
        model: persist.m,
        provider: extra.currentProvider || slug,
        models: mergeModelLists(extra.models, modelsFromEndpoints([persist])),
        persist,
      };
    }
    if (saved.kind === "abort")
      return { ok: false, error: "The model didn’t respond in time." };
    if (saved.kind === "error") return { ok: false, error: saved.error };
  }

  const persist: StoredEndpoint = {
    n: name,
    s: slug,
    u: llm,
    k: apiKey,
    m: model,
    ms: models,
    d: true,
  };
  return {
    ok: true,
    model,
    provider: slug,
    models: modelsFromEndpoints([persist]),
    persist,
  };
}

export async function streamOpenAiEndpoint(opts: {
  endpoint: StoredEndpoint;
  messages: ChatTurn[];
  model?: string;
  signal: AbortSignal;
}): Promise<Response> {
  const model =
    (opts.model || "").trim() &&
    (opts.endpoint.m === opts.model ||
      opts.endpoint.ms?.includes(opts.model || ""))
      ? opts.model!.trim()
      : opts.endpoint.m;
  const headers: Record<string, string> = {
    Accept: "text/event-stream",
    "Content-Type": "application/json",
  };
  if (opts.endpoint.k) headers.Authorization = `Bearer ${opts.endpoint.k}`;
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  let upstream: Response;
  try {
    upstream = await fetch(`${opts.endpoint.u}/chat/completions`, {
      method: "POST",
      headers,
      signal,
      cache: "no-store",
      redirect: "manual",
      body: JSON.stringify({
        model,
        stream: true,
        messages: opts.messages,
      }),
    });
  } catch (e) {
    if ((e as Error).name === "AbortError") {
      return ndjsonResponse(async (send) => {
        send({ type: "error", message: "The model didn’t respond in time." });
      }, 504);
    }
    return ndjsonResponse(async (send) => {
      send({ type: "error", message: FAIL });
    }, 502);
  }
  if (upstream.status === 401 || upstream.status === 403) {
    return ndjsonResponse(async (send) => {
      send({ type: "error", message: "The endpoint key is not correct." });
    }, 401);
  }
  if (!upstream.ok || !upstream.body) {
    return ndjsonResponse(
      async (send) => {
        send({ type: "error", message: FAIL });
      },
      upstream.status >= 400 ? upstream.status : 502,
    );
  }
  return ndjsonResponse(async (send) => {
    for await (const chunk of readSse(upstream.body!)) {
      const ev = eventFromChunk(chunk);
      if (ev) send(ev);
    }
  });
}

export async function streamHermesProxy(opts: {
  url: string;
  key: string;
  messages: ChatTurn[];
  conversationId?: string;
  model?: string;
  provider?: string;
  endpoints?: StoredEndpoint[];
  signal: AbortSignal;
  place?: GatewayPlace;
}): Promise<Response> {
  const base = await resolveHermesBase(opts.url, opts.place);
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  const custom = matchStoredEndpoint(opts.endpoints, opts.model, opts.provider);
  const requestedModel = custom?.d
    ? "hermes-agent"
    : opts.model?.trim() || "hermes-agent";
  const requestedProvider = custom?.d ? "" : opts.provider?.trim() || "";

  const post = (model: string, provider: string) =>
    fetch(`${base}/v1/chat/completions`, {
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
        model,
        stream: true,
        messages: opts.messages,
        ...(provider ? { provider } : {}),
      }),
    });

  let upstream = await post(requestedModel, requestedProvider);
  if (
    !upstream.ok &&
    (requestedModel !== "hermes-agent" || requestedProvider)
  ) {
    const retry = await post("hermes-agent", "");
    if (retry.ok) upstream = retry;
  }

  if (upstream.status === 401 || upstream.status === 403) {
    return ndjsonResponse(async (send) => {
      send({ type: "error", message: "The key is not correct." });
    }, 401);
  }
  if (!upstream.ok || !upstream.body) {
    const detail = hermesDetail(await hermesJson(upstream), FAIL);
    return ndjsonResponse(
      async (send) => {
        send({ type: "error", message: detail });
      },
      upstream.status >= 400 ? upstream.status : 502,
    );
  }

  return ndjsonResponse(async (send) => {
    let emitted = 0;
    for await (const chunk of readSse(upstream.body!)) {
      const ev = eventFromChunk(chunk);
      if (!ev) continue;
      send(ev);
      emitted += 1;
      if (ev.type === "error") return;
    }
    if (emitted === 0) {
      send({
        type: "error",
        message: "Hermes sent no text. Try again or switch models.",
      });
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

export function jsonWithCookie(
  body: unknown,
  status: number,
  cookie?: string | null,
) {
  const headers = new Headers({
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  if (cookie !== undefined) headers.append("Set-Cookie", gateSetCookie(cookie));
  return new Response(JSON.stringify(body), { status, headers });
}
