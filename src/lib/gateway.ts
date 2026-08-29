import { authHeaders } from "./auth/client";

export type GatewayMode = "direct" | "proxy";

export type GatewayPlace = "cloud" | "mac" | "device";

export type GatewayStatus = "idle" | "checking" | "live" | "down";

export type HermesModelOption = {
  id: string;
  label: string;
  provider: string;
  providerName?: string;
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

export const HERMES_USER_CHAR_LIMIT = 1375;
export const HERMES_NOTES_CHAR_LIMIT = 2200;

export type HermesMemoryStore = {
  raw: string;
  entries: string[];
  chars: number;
  limit: number;
};

export type HermesMemoryProfile = {
  name: string;
  current?: boolean;
  soul: string;
  user: HermesMemoryStore;
  notes: HermesMemoryStore;
};

export type HermesMemoryResult =
  | { ok: true; active: string; profiles: HermesMemoryProfile[] }
  | { ok: false; error: string };

export type ChatEvent =
  | { type: "delta"; text: string }
  | {
      type: "tool";
      name: string;
      status: "start" | "done";
      detail?: string;
      callId?: string;
    }
  | { type: "error"; message: string };

export type HermesChatContent =
  | string
  | Array<
      | { type: "text"; text: string }
      | {
          type: "image_url";
          image_url: { url: string; detail?: "auto" | "low" | "high" };
        }
    >;

export type ProbeCode =
  | "invalid"
  | "private"
  | "unauthorized"
  | "unreachable"
  | "cors"
  | "not_hermes";

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

const FAIL = "Couldn’t connect.";

export function friendlyProbeError(code?: ProbeCode): string {
  if (code === "unauthorized") return "The key is not correct.";
  if (code === "invalid") return "Check the address.";
  if (code === "cors") {
    return "Hermes is online, but it hasn’t allowed Alice yet (CORS).";
  }
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

export function normalizeLlmBaseUrl(raw: string): string {
  let s = raw.trim();
  if (!s) throw new GatewayError("invalid", FAIL);
  if (s.length > 512) throw new GatewayError("invalid", FAIL);
  if (!/^https?:\/\//i.test(s)) s = `https://${s}`;
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
  if (!path || path === "/") path = "/v1";
  return u.origin + path;
}

export function assertGatewayKey(raw: string): string {
  const k = raw.trim();
  if (k.length < 8 || k.length > 256) throw new GatewayError("invalid", FAIL);
  for (const char of k) {
    const code = char.charCodeAt(0);
    if (code <= 31 || code === 127) throw new GatewayError("invalid", FAIL);
  }
  return k;
}

export function isPrivateHostname(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (
    h === "localhost" ||
    h.endsWith(".localhost") ||
    h.endsWith(".local") ||
    h.endsWith(".ts.net") ||
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

/** Localhost / LAN → this browser (or this Mac if Alice hosts Hermes). Else the public URL. */
export function inferGatewayPlace(
  url: string,
  scope?: { owner?: boolean; local?: boolean },
): GatewayPlace {
  let host = "";
  try {
    host = new URL(normalizeGatewayUrl(url)).hostname;
  } catch {
    return "cloud";
  }
  if (!isPrivateHostname(host)) return "cloud";
  if (scope?.owner && scope.local) return "mac";
  return "device";
}

export async function forgetHermesSecret() {
  setMacSessionKey(null);
  try {
    const { setDeviceSessionKey } = await import("./hermes-direct");
    setDeviceSessionKey(null);
  } catch {
    //
  }
  try {
    await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "forget" }),
    });
  } catch {
    // local forget is enough
  }
}

export function providerSlug(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

export function prettyProvider(value?: string): string {
  if (!value) return "Hermes";
  const key = value.toLowerCase();
  const labels: Record<string, string> = {
    xai: "xAI",
    openai: "OpenAI",
    anthropic: "Anthropic",
    groq: "Groq",
    google: "Google",
    nous: "Nous",
    "nous-research": "Nous",
    "nous-portal": "Nous Portal",
    nousportal: "Nous Portal",
    hermes: "Hermes",
    grok: "xAI",
    openrouter: "OpenRouter",
    "openai-codex": "Codex",
    "openai-api": "OpenAI",
    custom: "Custom",
  };
  return labels[key] ?? value;
}

export function prettyModelLabel(id: string): string {
  const leaf = id.includes("/") ? id.slice(id.lastIndexOf("/") + 1) : id;
  return leaf
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b([a-z])/g, (c) => c.toUpperCase());
}

export function unionHermesModels(
  current: HermesModelOption[] | undefined,
  incoming: HermesModelOption[],
): HermesModelOption[] {
  const out: HermesModelOption[] = [];
  const seen = new Set<string>();
  for (const item of [...incoming, ...(current ?? [])]) {
    const key = `${item.provider}:${item.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
    if (out.length >= 400) break;
  }
  return out;
}

export function groupHermesModels(models: HermesModelOption[]): Array<{
  slug: string;
  name: string;
  models: HermesModelOption[];
}> {
  const groups: Array<{
    slug: string;
    name: string;
    models: HermesModelOption[];
  }> = [];
  const index = new Map<string, number>();
  for (const m of models) {
    const slug = m.provider || "hermes";
    let i = index.get(slug);
    if (i === undefined) {
      i = groups.length;
      index.set(slug, i);
      groups.push({
        slug,
        name: m.providerName || prettyProvider(slug),
        models: [],
      });
    }
    groups[i].models.push(m);
  }
  return groups;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function optionFromUnknown(
  value: unknown,
  provider = "",
  providerName?: string,
): HermesModelOption | null {
  if (typeof value === "string" && value.trim()) {
    const id = value.trim();
    return { id, label: prettyModelLabel(id), provider, providerName };
  }
  const rec = asRecord(value);
  if (!rec) return null;
  const id =
    typeof rec.id === "string"
      ? rec.id
      : typeof rec.model === "string"
        ? rec.model
        : "";
  if (!id) return null;
  const label =
    typeof rec.label === "string"
      ? rec.label
      : typeof rec.name === "string"
        ? rec.name
        : prettyModelLabel(id);
  const nextProvider =
    typeof rec.provider === "string"
      ? rec.provider
      : typeof rec.owned_by === "string"
        ? rec.owned_by
        : provider;
  return { id, label, provider: nextProvider, providerName };
}

function parsePickerProviders(rec: Record<string, unknown>): {
  models: HermesModelOption[];
  currentModel?: string;
  currentProvider?: string;
  source: "picker";
} {
  const providers = Array.isArray(rec.providers) ? rec.providers : [];
  const models: HermesModelOption[] = [];
  for (const raw of providers) {
    const row = asRecord(raw);
    if (!row) continue;
    const slug = typeof row.slug === "string" ? row.slug.trim() : "";
    if (!slug) continue;
    const name =
      typeof row.name === "string" && row.name.trim()
        ? row.name.trim()
        : prettyProvider(slug);
    const listed = Array.isArray(row.models) ? row.models : [];
    if (listed.length === 0) continue;
    const unavailable = new Set(
      Array.isArray(row.unavailable_models)
        ? row.unavailable_models.filter(
            (m): m is string => typeof m === "string",
          )
        : [],
    );
    for (const item of listed) {
      const option = optionFromUnknown(item, slug, name);
      if (!option || unavailable.has(option.id)) continue;
      models.push(option);
    }
  }
  const currentModel =
    (typeof rec.model === "string" && rec.model) ||
    (typeof rec.current_model === "string" && rec.current_model) ||
    undefined;
  const currentProvider =
    (typeof rec.provider === "string" && rec.provider) ||
    (typeof rec.current_provider === "string" && rec.current_provider) ||
    models.find((m) => m.id === currentModel)?.provider;
  return { models, currentModel, currentProvider, source: "picker" };
}

export function parseHermesModelOptions(body: unknown): {
  models: HermesModelOption[];
  currentModel?: string;
  currentProvider?: string;
  source: "picker" | "compat";
} {
  const rec = asRecord(body);
  if (rec && Array.isArray(rec.providers)) {
    return parsePickerProviders(rec);
  }
  const list = Array.isArray(body)
    ? body
    : Array.isArray(rec?.data)
      ? rec.data
      : Array.isArray(rec?.models)
        ? rec.models
        : [];
  const models = list
    .map((item) => optionFromUnknown(item))
    .filter((m): m is HermesModelOption => m !== null);
  const currentModel =
    (typeof rec?.model === "string" && rec.model) ||
    (typeof rec?.current_model === "string" && rec.current_model) ||
    models[0]?.id;
  const currentProvider =
    (typeof rec?.provider === "string" && rec.provider) ||
    (typeof rec?.current_provider === "string" && rec.current_provider) ||
    models.find((m) => m.id === currentModel)?.provider;
  return { models, currentModel, currentProvider, source: "compat" };
}

export function modelFromList(body: unknown): string {
  return parseHermesModelOptions(body).currentModel || "hermes-agent";
}

export function parseSkillNames(body: unknown): string[] {
  const rec = asRecord(body);
  const list = Array.isArray(body)
    ? body
    : Array.isArray(rec?.data)
      ? rec.data
      : Array.isArray(rec?.skills)
        ? rec.skills
        : [];
  const names: string[] = [];
  for (const item of list) {
    if (typeof item === "string" && item.trim()) names.push(item.trim());
    else {
      const row = asRecord(item);
      const name =
        (typeof row?.name === "string" && row.name) ||
        (typeof row?.id === "string" && row.id) ||
        "";
      if (name) names.push(name);
    }
  }
  return names;
}

export async function enrichWithModelOptions(
  base: string,
  token: string,
  signal: AbortSignal,
  fallback: {
    models: HermesModelOption[];
    currentModel?: string;
    currentProvider?: string;
  },
  refresh = false,
): Promise<{
  models: HermesModelOption[];
  currentModel?: string;
  currentProvider?: string;
}> {
  const paths = [
    "/api/model/options?include_unconfigured=1",
    "/api/model/options?refresh=1&include_unconfigured=1",
    "/api/model/options",
    "/api/models",
    ...(refresh
      ? ["/api/model/options?refresh=1", "/api/models?refresh=1"]
      : []),
  ];
  const headerSets: HeadersInit[] = [
    {
      Authorization: `Bearer ${token}`,
      "X-Hermes-Session-Token": token,
      Accept: "application/json",
    },
    { Authorization: `Bearer ${token}`, Accept: "application/json" },
  ];
  for (const path of paths) {
    for (const headers of headerSets) {
      try {
        const res = await fetch(`${base}${path}`, {
          headers,
          signal,
          cache: "no-store",
          redirect: "manual",
        });
        if (!res.ok) continue;
        const parsed = parseHermesModelOptions(await res.json());
        if (parsed.models.length === 0) continue;
        return {
          models: unionHermesModels(fallback.models, parsed.models),
          currentModel: parsed.currentModel || fallback.currentModel,
          currentProvider: parsed.currentProvider || fallback.currentProvider,
        };
      } catch {
        // try next
      }
    }
  }
  return fallback;
}

export async function* readSse(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  const reader = body.getReader();
  let buf = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const frames = buf.split(/\r?\n\r?\n/);
      buf = frames.pop() ?? "";
      for (const frame of frames) {
        const payload = sseData(frame);
        if (payload) yield payload;
      }
    }
    buf += decoder.decode();
    const payload = sseData(buf);
    if (payload) yield payload;
  } finally {
    reader.releaseLock();
  }
}

function sseData(frame: string): string | null {
  let event = "";
  const data: string[] = [];
  for (const rawLine of frame.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.startsWith("event:")) event = line.slice(6).trim();
    else if (line.startsWith("data:")) data.push(line.slice(5).trim());
  }
  const payload = data.join("\n");
  if (!payload || payload === "[DONE]") return null;
  if (!event) return payload;
  try {
    const parsed = JSON.parse(payload) as Record<string, unknown>;
    return JSON.stringify({ ...parsed, type: event });
  } catch {
    return payload;
  }
}

function textFromContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => {
      if (typeof part === "string") return part;
      if (!part || typeof part !== "object") return "";
      const rec = part as Record<string, unknown>;
      if (typeof rec.text === "string") return rec.text;
      if (typeof rec.content === "string") return rec.content;
      return "";
    })
    .join("");
}

export function eventFromChunk(chunk: string): ChatEvent | null {
  try {
    const json = JSON.parse(chunk) as {
      type?: string;
      delta?: string;
      tool_name?: string;
      tool?: string;
      preview?: string;
      label?: string;
      status?: string;
      toolCallId?: string;
      error?: { message?: string } | string;
      hermes?: { error?: string; failed?: boolean };
      choices?: Array<{
        delta?: {
          content?: unknown;
          tool_calls?: Array<{ id?: string; function?: { name?: string } }>;
        };
        message?: { content?: unknown };
        finish_reason?: string | null;
      }>;
    };
    const err =
      (typeof json.error === "string" && json.error) ||
      (json.error && typeof json.error === "object" && json.error.message) ||
      json.hermes?.error;
    if (err) return { type: "error", message: err };
    if (json.choices?.[0]?.finish_reason === "error") {
      return { type: "error", message: FAIL };
    }
    if (
      json.type === "assistant.delta" &&
      typeof json.delta === "string" &&
      json.delta
    ) {
      return { type: "delta", text: json.delta };
    }
    if (json.type === "tool.started") {
      const name = json.tool_name || json.tool;
      if (name)
        return { type: "tool", name, status: "start", detail: json.preview };
    }
    if (json.type === "tool.completed" || json.type === "tool.failed") {
      const name = json.tool_name || json.tool;
      if (name)
        return { type: "tool", name, status: "done", detail: json.preview };
    }
    if (json.type === "hermes.tool.progress" && json.tool) {
      return {
        type: "tool",
        name: json.tool,
        status: json.status === "completed" ? "done" : "start",
        detail: json.label,
        callId: json.toolCallId,
      };
    }
    const delta = json.choices?.[0]?.delta;
    const deltaText = textFromContent(delta?.content);
    if (deltaText) return { type: "delta", text: deltaText };
    const messageText = textFromContent(json.choices?.[0]?.message?.content);
    if (messageText) return { type: "delta", text: messageText };
    const toolName = delta?.tool_calls?.[0]?.function?.name;
    if (toolName) {
      return {
        type: "tool",
        name: toolName,
        status: "start",
        callId: delta?.tool_calls?.[0]?.id,
      };
    }
    return null;
  } catch {
    return null;
  }
}

type HermesActionResult = ProbeResult & {
  models?: HermesModelOption[];
};

export async function probeGateway(opts: {
  url: string;
  key?: string;
  place: GatewayPlace;
  save?: boolean;
  signal?: AbortSignal;
}): Promise<ProbeResult> {
  if (opts.place === "device") {
    const { getDeviceSessionKey, probeHermesDirect } =
      await import("./hermes-direct");
    const key = opts.key || getDeviceSessionKey() || "";
    return probeHermesDirect({
      url: opts.url,
      key,
      save: opts.save,
      signal: opts.signal,
    });
  }
  try {
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: opts.save ? "connect" : "probe",
        url: opts.url,
        key: opts.key,
        place: opts.place,
      }),
      signal: opts.signal,
    });
    const data = (await res.json()) as HermesActionResult;
    if (data.ok) return data;
    return {
      ok: false,
      code: (data as { code?: ProbeCode }).code ?? "unreachable",
      error: friendlyProbeError((data as { code?: ProbeCode }).code),
    };
  } catch (e) {
    if ((e as Error).name === "AbortError") {
      return { ok: false, code: "unreachable", error: friendlyProbeError() };
    }
    return { ok: false, code: "cors", error: friendlyProbeError() };
  }
}

export async function listHermesModels(opts?: {
  refresh?: boolean;
  signal?: AbortSignal;
}): Promise<{
  ok: boolean;
  models: HermesModelOption[];
  currentModel?: string;
  currentProvider?: string;
}> {
  try {
    const { useHermes } = await import("./store");
    const place = useHermes.getState().gatewayPlace;
    if (place === "device") {
      const { getDeviceSessionKey, listHermesModelsDirect } =
        await import("./hermes-direct");
      const url = useHermes.getState().gatewayUrl;
      const key = getDeviceSessionKey();
      if (!url || !key) return { ok: false, models: [] };
      return listHermesModelsDirect({
        url,
        key,
        refresh: opts?.refresh,
        signal: opts?.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "models",
        refresh: Boolean(opts?.refresh),
      }),
      signal: opts?.signal,
    });
    const data = (await res.json()) as {
      ok?: boolean;
      models?: HermesModelOption[];
      currentModel?: string;
      currentProvider?: string;
    };
    return {
      ok: Boolean(data.ok),
      models: Array.isArray(data.models) ? data.models : [],
      currentModel: data.currentModel,
      currentProvider: data.currentProvider,
    };
  } catch {
    return { ok: false, models: [] };
  }
}

export async function saveHermesCustomEndpoint(opts: {
  name?: string;
  baseUrl: string;
  apiKey?: string;
  model?: string;
}): Promise<{
  ok: boolean;
  error?: string;
  model?: string;
  provider?: string;
  models?: HermesModelOption[];
}> {
  try {
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "custom-endpoint",
        endpointName: opts.name,
        endpointUrl: opts.baseUrl,
        endpointKey: opts.apiKey,
        endpointModel: opts.model,
      }),
    });
    const data = (await res.json()) as {
      ok?: boolean;
      error?: string;
      model?: string;
      provider?: string;
      models?: HermesModelOption[];
    };
    return {
      ok: Boolean(data.ok),
      error: typeof data.error === "string" ? data.error : undefined,
      model: data.model,
      provider: data.provider,
      models: Array.isArray(data.models) ? data.models : [],
    };
  } catch {
    return { ok: false, error: FAIL, models: [] };
  }
}

export async function setHermesModel(opts: {
  url: string;
  key?: string;
  place: GatewayPlace;
  model: string;
  provider?: string;
  conversationId?: string;
}): Promise<{ ok: boolean }> {
  if (opts.place === "device") {
    const { getDeviceSessionKey, setHermesModelDirect } =
      await import("./hermes-direct");
    const key = opts.key || getDeviceSessionKey();
    if (!key) return { ok: false };
    return setHermesModelDirect({
      url: opts.url,
      key,
      model: opts.model,
      provider: opts.provider,
      conversationId: opts.conversationId,
    });
  }
  try {
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "set-model",
        url: opts.url,
        key: opts.key,
        place: opts.place,
        model: opts.model,
        provider: opts.provider,
        conversationId: opts.conversationId,
      }),
    });
    const data = (await res.json()) as { ok?: boolean };
    return { ok: Boolean(data.ok) };
  } catch {
    return { ok: false };
  }
}

export async function listHermesMemory(opts?: {
  signal?: AbortSignal;
}): Promise<HermesMemoryResult> {
  try {
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "memory" }),
      signal: opts?.signal,
    });
    const data = (await res.json()) as HermesMemoryResult;
    if (data && data.ok && Array.isArray(data.profiles)) return data;
    return { ok: false, error: "Couldn’t read Hermes memory." };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes memory." };
  }
}
