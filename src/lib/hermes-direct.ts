import {
  assertGatewayKey,
  enrichWithModelOptions,
  eventFromChunk,
  GatewayError,
  normalizeGatewayUrl,
  parseHermesModelOptions,
  parseSkillNames,
  readSse,
  type ChatEvent,
  type HermesModelOption,
  type ProbeResult,
} from "./gateway";
import type { HermesLive, HermesLiveResult } from "./hermes-live";
import {
  asRec,
  channelsFromApi,
  cronFromApi,
  mcpFromApi,
  pairingList,
  projectsFromApi,
  sessionsFromApi,
  skillsFromApi,
  toolsetsFromApi,
  webhooksFromApi,
} from "./hermes-live-parse";

const FAIL = "Couldn’t connect.";
const DEVICE_KEY = "alice-device-hermes-key";

export const DEFAULT_DEVICE_HERMES = "http://127.0.0.1:8642";

export function getDeviceSessionKey(): string | null {
  if (typeof sessionStorage === "undefined") return null;
  return sessionStorage.getItem(DEVICE_KEY);
}

export function setDeviceSessionKey(key: string | null) {
  if (typeof sessionStorage === "undefined") return;
  if (key) sessionStorage.setItem(DEVICE_KEY, key);
  else sessionStorage.removeItem(DEVICE_KEY);
}

function headers(token: string, extra?: Record<string, string>): HeadersInit {
  return {
    Authorization: `Bearer ${token}`,
    "X-Hermes-Session-Token": token,
    Accept: "application/json",
    ...extra,
  };
}

function bases(url: string): string[] {
  const base = normalizeGatewayUrl(url);
  const out = [base];
  try {
    const u = new URL(base);
    if (u.port !== "9119") {
      const dash = `${u.protocol}//${u.hostname}:9119`;
      if (!out.includes(dash)) out.push(dash);
    }
  } catch {
    // keep the connected URL
  }
  return out;
}

function corsFail(): ProbeResult {
  return {
    ok: false,
    code: "cors",
    error:
      "This browser can’t reach your Hermes. Open it on the same computer, or let Hermes allow this origin (CORS).",
  };
}

export async function probeHermesDirect(opts: {
  url: string;
  key: string;
  save?: boolean;
  signal?: AbortSignal;
}): Promise<ProbeResult> {
  try {
    const base = normalizeGatewayUrl(opts.url);
    const token = assertGatewayKey(opts.key);
    const ctrl = opts.signal ?? AbortSignal.timeout(12_000);
    const hdrs = headers(token);
    let modelsRes: Response;
    try {
      modelsRes = await fetch(`${base}/v1/models`, {
        headers: hdrs,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
      });
    } catch (e) {
      if ((e as Error).name === "AbortError") {
        return { ok: false, code: "unreachable", error: FAIL };
      }
      return corsFail();
    }
    if (modelsRes.status >= 300 && modelsRes.status < 400) {
      return { ok: false, code: "not_hermes", error: FAIL };
    }
    if (modelsRes.status === 401 || modelsRes.status === 403) {
      return { ok: false, code: "unauthorized", error: "The key is not correct." };
    }
    if (!modelsRes.ok) return { ok: false, code: "not_hermes", error: FAIL };

    const parsed = parseHermesModelOptions(await modelsRes.json());
    let model = parsed.currentModel || "hermes-agent";
    let provider = parsed.currentProvider;
    let models: HermesModelOption[] = parsed.models;
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

    let platform: string | undefined;
    let skills: string[] | undefined;
    try {
      const cap = await fetch(`${base}/v1/capabilities`, {
        headers: hdrs,
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
        headers: hdrs,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
      });
      if (sk.ok) skills = parseSkillNames(await sk.json());
    } catch {
      // optional
    }

    if (opts.save) setDeviceSessionKey(token);
    return { ok: true, model, provider, models, platform, skills, mode: "direct" };
  } catch (e) {
    if (e instanceof GatewayError) return { ok: false, code: e.code, error: e.message };
    return corsFail();
  }
}

export async function* streamHermesDirect(opts: {
  url: string;
  key: string;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
  conversationId?: string;
  model?: string;
  provider?: string;
  signal: AbortSignal;
}): AsyncGenerator<ChatEvent> {
  const base = normalizeGatewayUrl(opts.url);
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  const requestedModel = opts.model?.trim() || "hermes-agent";
  const requestedProvider = opts.provider?.trim() || "";

  const post = (model: string, provider: string) =>
    fetch(`${base}/v1/chat/completions`, {
      method: "POST",
      headers: headers(token, {
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

  let upstream: Response;
  try {
    upstream = await post(requestedModel, requestedProvider);
    if (!upstream.ok && (requestedModel !== "hermes-agent" || requestedProvider)) {
      const retry = await post("hermes-agent", "");
      if (retry.ok) upstream = retry;
    }
  } catch (e) {
    if ((e as Error).name === "AbortError") return;
    const fail = corsFail();
    yield { type: "error", message: fail.ok ? FAIL : fail.error };
    return;
  }

  if (upstream.status === 401 || upstream.status === 403) {
    yield { type: "error", message: "The key is not correct." };
    return;
  }
  if (!upstream.ok || !upstream.body) {
    yield { type: "error", message: FAIL };
    return;
  }

  let emitted = 0;
  for await (const chunk of readSse(upstream.body)) {
    const ev = eventFromChunk(chunk);
    if (!ev) continue;
    yield ev;
    emitted += 1;
    if (ev.type === "error") return;
  }
  if (emitted === 0) {
    yield {
      type: "error",
      message: "Hermes sent no text. Try again or switch models.",
    };
  }
}

export async function listHermesModelsDirect(opts: {
  url: string;
  key: string;
  refresh?: boolean;
  signal?: AbortSignal;
}): Promise<{
  ok: boolean;
  models: HermesModelOption[];
  currentModel?: string;
  currentProvider?: string;
}> {
  try {
    const base = normalizeGatewayUrl(opts.url);
    const token = assertGatewayKey(opts.key);
    const ctrl = opts.signal ?? AbortSignal.timeout(20_000);
    const res = await fetch(`${base}/v1/models`, {
      headers: headers(token),
      signal: ctrl,
      cache: "no-store",
      redirect: "manual",
    });
    if (!res.ok) return { ok: false, models: [] };
    let acc = parseHermesModelOptions(await res.json());
    const extra = await enrichWithModelOptions(
      base,
      token,
      ctrl,
      {
        models: acc.models,
        currentModel: acc.currentModel,
        currentProvider: acc.currentProvider,
      },
      Boolean(opts.refresh),
    );
    return {
      ok: true,
      models: extra.models,
      currentModel: extra.currentModel,
      currentProvider: extra.currentProvider,
    };
  } catch {
    return { ok: false, models: [] };
  }
}

export async function setHermesModelDirect(opts: {
  url: string;
  key: string;
  model: string;
  provider?: string;
  conversationId?: string;
}): Promise<{ ok: boolean }> {
  try {
    const base = normalizeGatewayUrl(opts.url);
    const token = assertGatewayKey(opts.key);
    const ctrl = AbortSignal.timeout(12_000);
    const provider = (opts.provider || "").trim();
    const setRes = await fetch(`${base}/api/model/set`, {
      method: "POST",
      headers: headers(token, { "Content-Type": "application/json" }),
      signal: ctrl,
      cache: "no-store",
      redirect: "manual",
      body: JSON.stringify({ scope: "main", model: opts.model, provider }),
    });
    if (setRes.ok) return { ok: true };
    const command = provider
      ? `/model ${opts.model} --provider ${provider} --global`
      : `/model ${opts.model} --global`;
    const chatRes = await fetch(`${base}/v1/chat/completions`, {
      method: "POST",
      headers: headers(token, {
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
      }),
    });
    return { ok: chatRes.ok };
  } catch {
    return { ok: false };
  }
}

async function dashboardGet(url: string, key: string, path: string, signal?: AbortSignal): Promise<unknown> {
  const token = assertGatewayKey(key);
  const ctrl = signal ?? AbortSignal.timeout(12_000);
  const hdrs = headers(token);
  for (const apiBase of bases(url)) {
    try {
      const res = await fetch(`${apiBase}${path}`, {
        headers: hdrs,
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

async function dashboardSend(
  url: string,
  key: string,
  path: string,
  method: string,
  body?: unknown,
): Promise<boolean> {
  const token = assertGatewayKey(key);
  const ctrl = AbortSignal.timeout(12_000);
  const hdrs = headers(token, { "Content-Type": "application/json" });
  for (const apiBase of bases(url)) {
    try {
      const res = await fetch(`${apiBase}${path}`, {
        method,
        headers: hdrs,
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

export async function listHermesLiveDirect(opts: {
  url: string;
  key: string;
  signal?: AbortSignal;
}): Promise<HermesLiveResult> {
  try {
    const [apiSkills, apiTools, apiMcp, apiCron, apiChannels, apiSessions, apiPairing, apiHooks, apiProjects] =
      await Promise.all([
        dashboardGet(opts.url, opts.key, "/api/skills", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/tools/toolsets", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/mcp/servers", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/cron/jobs", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/messaging/platforms", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/sessions?limit=20&order=recent", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/pairing", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/webhooks", opts.signal),
        dashboardGet(opts.url, opts.key, "/api/projects", opts.signal),
      ]);
    return {
      ok: true,
      writable: true,
      owner: false,
      local: false,
      skills: skillsFromApi(apiSkills),
      toolsets: toolsetsFromApi(apiTools),
      mcp: mcpFromApi(apiMcp),
      cron: cronFromApi(apiCron),
      channels: channelsFromApi(apiChannels),
      sessions: sessionsFromApi(apiSessions),
      pairing: pairingList(asRec(apiPairing).pending),
      pairingApproved: pairingList(asRec(apiPairing).approved),
      webhooks: webhooksFromApi(apiHooks),
      projects: projectsFromApi(apiProjects),
    } satisfies HermesLive;
  } catch {
    return { ok: false, error: "Couldn’t read Hermes status." };
  }
}

export async function mutateHermesDirect(opts: {
  url: string;
  key: string;
  action: "toggle-skill" | "toggle-toolset" | "toggle-mcp" | "cron-pause" | "cron-resume";
  name?: string;
  enabled?: boolean;
  jobId?: string;
}): Promise<{ ok: boolean; error?: string }> {
  try {
    let ok = false;
    if (opts.action === "toggle-skill" && opts.name) {
      ok = await dashboardSend(opts.url, opts.key, "/api/skills/toggle", "PUT", {
        name: opts.name,
        enabled: Boolean(opts.enabled),
      });
    } else if (opts.action === "toggle-toolset" && opts.name) {
      ok = await dashboardSend(
        opts.url,
        opts.key,
        `/api/tools/toolsets/${encodeURIComponent(opts.name)}`,
        "PUT",
        { enabled: Boolean(opts.enabled) },
      );
    } else if (opts.action === "toggle-mcp" && opts.name) {
      ok = await dashboardSend(
        opts.url,
        opts.key,
        `/api/mcp/servers/${encodeURIComponent(opts.name)}/enabled`,
        "PUT",
        { enabled: Boolean(opts.enabled) },
      );
    } else if (opts.action === "cron-pause" && opts.jobId) {
      ok = await dashboardSend(
        opts.url,
        opts.key,
        `/api/cron/jobs/${encodeURIComponent(opts.jobId)}/pause`,
        "POST",
      );
    } else if (opts.action === "cron-resume" && opts.jobId) {
      ok = await dashboardSend(
        opts.url,
        opts.key,
        `/api/cron/jobs/${encodeURIComponent(opts.jobId)}/resume`,
        "POST",
      );
    }
    return ok ? { ok: true } : { ok: false, error: "Hermes couldn’t save the change." };
  } catch {
    return { ok: false, error: "Hermes couldn’t save the change." };
  }
}
