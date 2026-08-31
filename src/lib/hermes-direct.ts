import {
  assertGatewayKey,
  enrichWithModelOptions,
  eventFromChunk,
  GatewayError,
  normalizeGatewayUrl,
  parseHermesModelOptions,
  parseSkillNames,
  readSse,
  scopeHermesGatewayBase,
  scopeHermesManagementPath,
  type ChatEvent,
  type HermesChatContent,
  type HermesModelOption,
  type ProbeResult,
} from "./gateway";
import {
  parseHermesCapabilityManifest,
  type HermesCapabilityManifest,
} from "./gateway-contracts";
import {
  hermesScopedOperationFor,
  type HermesMutation,
} from "./hermes-operations";
import type {
  HermesActionStatusResult,
  HermesDiagnosticsResult,
  HermesLive,
  HermesLiveResult,
  HermesMutationResult,
  HermesProfileSoulResult,
  HermesProfilesResult,
  HermesSessionMessagesResult,
  HermesSkillContentResult,
  HermesSkillHubSearchResult,
  HermesSystemToolsResult,
  HermesToolsetDetailsResult,
} from "./hermes-live-types";
import { authHeaders } from "./auth/client";
import { setDeviceSessionKey } from "./hermes-secret-client";
import {
  controlHermesRun,
  getHermesRunSnapshot,
  startHermesRun,
  streamStartedHermesRun,
} from "./hermes-run-transport";
import type { HermesApprovalChoice } from "./gateway-contracts";
import type { HermesRunSnapshot } from "./hermes-runs";
import { streamHermesSessionChat } from "./hermes-session-chat-transport";
import {
  asRec,
  channelTestFromApi,
  channelsFromApi,
  cronDeliveryTargetsFromApi,
  cronFromApi,
  curatorFromApi,
  diagnosticsFromApi,
  mcpFromApi,
  pairingList,
  projectsFromApi,
  pluginsFromApi,
  profilesFromApi,
  sessionsFromApi,
  sessionMessagesFromApi,
  skillHubResultsFromApi,
  skillsFromApi,
  str,
  systemToolsFromApi,
  toolsetsFromApi,
  toolsetDetailsFromApi,
  webhookCreationFromApi,
  webhooksFromApi,
} from "./hermes-live-parse";

const FAIL = "Couldn’t connect.";

export const DEFAULT_DEVICE_HERMES = "http://127.0.0.1:8642";

export {
  getDeviceSessionKey,
  setDeviceSessionKey,
} from "./hermes-secret-client";

export async function loadSavedDeviceConnection(opts?: {
  url?: string;
  signal?: AbortSignal;
}): Promise<{ url: string; key: string } | null> {
  try {
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "device-secret" }),
      signal: opts?.signal,
      cache: "no-store",
    });
    if (!res.ok) return null;
    const data = (await res.json()) as {
      ok?: boolean;
      url?: unknown;
      key?: unknown;
    };
    if (
      !data.ok ||
      typeof data.url !== "string" ||
      typeof data.key !== "string"
    ) {
      return null;
    }
    const url = normalizeGatewayUrl(data.url);
    if (opts?.url && normalizeGatewayUrl(opts.url) !== url) return null;
    const key = assertGatewayKey(data.key);
    setDeviceSessionKey(key);
    return { url, key };
  } catch {
    return null;
  }
}

export async function saveDeviceConnection(opts: {
  url: string;
  key: string;
  signal?: AbortSignal;
}): Promise<boolean> {
  try {
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "store-device",
        url: normalizeGatewayUrl(opts.url),
        key: assertGatewayKey(opts.key),
      }),
      signal: opts.signal,
      cache: "no-store",
    });
    return res.ok;
  } catch {
    return false;
  }
}

function headers(token: string, extra?: Record<string, string>): HeadersInit {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    ...extra,
  };
}

function bases(url: string): string[] {
  const base = normalizeGatewayUrl(url);
  const out = [base];
  try {
    const u = new URL(base);
    if (!out.includes(u.origin)) out.push(u.origin);
    if (u.hostname.toLowerCase().endsWith(".ts.net")) return out;
    if (u.port !== "9119") {
      const dash = `${u.protocol}//${u.hostname}:9119`;
      if (!out.includes(dash)) out.push(dash);
    }
  } catch {
    // keep the connected URL
  }
  return out;
}

const CORS_ERROR = "Hermes is online, but it hasn’t allowed Alice yet (CORS).";

function corsFail(): ProbeResult {
  return {
    ok: false,
    code: "cors",
    error: CORS_ERROR,
  };
}

function unreachableFail(base: string): ProbeResult {
  let hostname = "";
  try {
    hostname = new URL(base).hostname.toLowerCase();
  } catch {
    // The URL has already been normalized; keep the general fallback.
  }

  if (
    hostname === "localhost" ||
    hostname === "127.0.0.1" ||
    hostname === "::1"
  ) {
    return {
      ok: false,
      code: "unreachable",
      error:
        "This address points to this phone. Use the HTTPS or Tailscale address shown by Hermes.",
    };
  }

  if (hostname.endsWith(".ts.net")) {
    return {
      ok: false,
      code: "unreachable",
      error:
        "Hermes isn’t reachable. Open Tailscale on this phone and make sure Hermes is running.",
    };
  }

  return {
    ok: false,
    code: "unreachable",
    error:
      "Hermes isn’t reachable. Make sure it’s running and this phone can open its address.",
  };
}

async function reachableWithoutCors(
  base: string,
  signal?: AbortSignal,
): Promise<boolean> {
  if (signal?.aborted) return false;
  try {
    const reachabilitySignal = signal
      ? AbortSignal.any([signal, AbortSignal.timeout(5_000)])
      : AbortSignal.timeout(5_000);
    await fetch(`${base}/v1/models`, {
      mode: "no-cors",
      credentials: "omit",
      cache: "no-store",
      signal: reachabilitySignal,
    });
    return true;
  } catch {
    return false;
  }
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
        return unreachableFail(base);
      }
      return (await reachableWithoutCors(base, opts.signal))
        ? corsFail()
        : unreachableFail(base);
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
    let manifest: HermesCapabilityManifest | undefined;
    try {
      const cap = await fetch(`${base}/v1/capabilities`, {
        headers: hdrs,
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
    return {
      ok: true,
      model,
      provider,
      models,
      platform,
      skills,
      manifest,
      mode: "direct",
    };
  } catch (e) {
    if (e instanceof GatewayError)
      return { ok: false, code: e.code, error: e.message };
    return corsFail();
  }
}

export async function* streamHermesDirect(opts: {
  url: string;
  key: string;
  messages: Array<{ role: "user" | "assistant"; content: HermesChatContent }>;
  conversationId?: string;
  model?: string;
  provider?: string;
  preferRuns?: boolean;
  signal: AbortSignal;
  profile?: string;
}): AsyncGenerator<ChatEvent> {
  const base = scopeHermesGatewayBase(
    normalizeGatewayUrl(opts.url),
    opts.profile,
  );
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  const requestedModel = opts.model?.trim() || "hermes-agent";
  const requestedProvider = opts.provider?.trim() || "";

  if (opts.preferRuns) {
    try {
      const started = await startHermesRun({
        fetch,
        base,
        token,
        signal,
        messages: opts.messages,
        conversationId: opts.conversationId,
        model: requestedModel,
        provider: requestedProvider,
      });
      if (started.ok) {
        yield* streamStartedHermesRun({
          fetch,
          base,
          token,
          signal,
          run: started.run,
          conversationId: opts.conversationId,
        });
        return;
      }
      if (!started.unsupported) {
        yield { type: "error", message: started.message };
        return;
      }
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      yield { type: "error", message: CORS_ERROR };
      return;
    }
  }

  const post = (model: string, provider: string) =>
    fetch(`${base}/v1/chat/completions`, {
      method: "POST",
      headers: headers(token, {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
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
    if (
      !upstream.ok &&
      (requestedModel !== "hermes-agent" || requestedProvider)
    ) {
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

export async function* streamHermesSessionDirect(opts: {
  url: string;
  key: string;
  sessionId: string;
  message: HermesChatContent;
  conversationId?: string;
  model?: string;
  provider?: string;
  signal: AbortSignal;
  profile?: string;
}): AsyncGenerator<ChatEvent> {
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  try {
    yield* streamHermesSessionChat({
      fetch,
      base: scopeHermesGatewayBase(normalizeGatewayUrl(opts.url), opts.profile),
      token: assertGatewayKey(opts.key),
      sessionId: opts.sessionId,
      message: opts.message,
      conversationId: opts.conversationId,
      model: opts.model,
      provider: opts.provider,
      signal,
    });
  } catch (error) {
    if ((error as Error).name === "AbortError") return;
    yield { type: "error", message: CORS_ERROR };
  }
}

export async function getHermesRunDirect(opts: {
  url: string;
  key: string;
  runId: string;
  conversationId?: string;
  signal: AbortSignal;
  profile?: string;
}): Promise<HermesRunSnapshot | null> {
  return getHermesRunSnapshot({
    fetch,
    base: scopeHermesGatewayBase(normalizeGatewayUrl(opts.url), opts.profile),
    token: assertGatewayKey(opts.key),
    runId: opts.runId,
    conversationId: opts.conversationId,
    signal: opts.signal,
  });
}

export async function controlHermesRunDirect(opts: {
  url: string;
  key: string;
  runId: string;
  action: "stop" | "approval" | "steer";
  choice?: HermesApprovalChoice;
  resolveAll?: boolean;
  profile?: string;
  input?: string;
  signal: AbortSignal;
}): Promise<boolean> {
  const common = {
    fetch,
    base: scopeHermesGatewayBase(normalizeGatewayUrl(opts.url), opts.profile),
    token: assertGatewayKey(opts.key),
    runId: opts.runId,
    signal: opts.signal,
  };
  if (opts.action === "approval" && opts.choice) {
    return controlHermesRun({
      ...common,
      action: "approval",
      choice: opts.choice,
      resolveAll: opts.resolveAll,
    });
  }
  if (opts.action === "steer" && opts.input?.trim()) {
    return controlHermesRun({
      ...common,
      action: "steer",
      input: opts.input.trim().slice(0, 8_000),
    });
  }
  return opts.action === "stop"
    ? controlHermesRun({ ...common, action: "stop" })
    : false;
}

export async function listHermesModelsDirect(opts: {
  url: string;
  key: string;
  refresh?: boolean;
  signal?: AbortSignal;
  profile?: string;
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
    const gatewayBase = scopeHermesGatewayBase(base, opts.profile);
    const res = await fetch(`${gatewayBase}/v1/models`, {
      headers: headers(token),
      signal: ctrl,
      cache: "no-store",
      redirect: "manual",
    });
    if (!res.ok) return { ok: false, models: [] };
    const acc = parseHermesModelOptions(await res.json());
    const extra = await enrichWithModelOptions(
      base,
      token,
      ctrl,
      {
        models: acc.models,
        currentModel: acc.currentModel,
        currentProvider: acc.currentProvider,
      },
      { refresh: Boolean(opts.refresh), profile: opts.profile },
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
  profile?: string;
}): Promise<{ ok: boolean }> {
  try {
    const base = normalizeGatewayUrl(opts.url);
    const token = assertGatewayKey(opts.key);
    const ctrl = AbortSignal.timeout(12_000);
    const provider = (opts.provider || "").trim();
    const setRes = await fetch(
      `${base}${scopeHermesManagementPath("/api/model/set", opts.profile)}`,
      {
        method: "POST",
        headers: headers(token, { "Content-Type": "application/json" }),
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
        body: JSON.stringify({ scope: "main", model: opts.model, provider }),
      },
    );
    if (setRes.ok) return { ok: true };
    const command = provider
      ? `/model ${opts.model} --provider ${provider} --global`
      : `/model ${opts.model} --global`;
    const gatewayBase = scopeHermesGatewayBase(base, opts.profile);
    const chatRes = await fetch(`${gatewayBase}/v1/chat/completions`, {
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

async function dashboardGet(
  url: string,
  key: string,
  path: string,
  signal?: AbortSignal,
): Promise<unknown> {
  const token = assertGatewayKey(key);
  const hdrs = headers(token);
  for (const apiBase of bases(url)) {
    try {
      const ctrl = signal
        ? AbortSignal.any([signal, AbortSignal.timeout(8_000)])
        : AbortSignal.timeout(8_000);
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
      if (signal?.aborted && (e as Error).name === "AbortError") throw e;
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
  return dashboardMutate(url, key, path, method, body, false);
}

function profiledPath(path: string, profile?: string): string {
  if (!profile) return path;
  const separator = path.includes("?") ? "&" : "?";
  return `${path}${separator}profile=${encodeURIComponent(profile)}`;
}

async function dashboardSendJson(
  url: string,
  key: string,
  path: string,
  method: string,
  body?: unknown,
): Promise<unknown> {
  return dashboardMutate(url, key, path, method, body, true);
}

async function dashboardMutate(
  url: string,
  key: string,
  path: string,
  method: string,
  body: unknown,
  parseJson: false,
): Promise<boolean>;
async function dashboardMutate(
  url: string,
  key: string,
  path: string,
  method: string,
  body: unknown,
  parseJson: true,
): Promise<unknown>;
async function dashboardMutate(
  url: string,
  key: string,
  path: string,
  method: string,
  body: unknown,
  parseJson: boolean,
): Promise<boolean | unknown> {
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
      if (!res.ok) continue;
      if (!parseJson) return true;
      const text = await res.text();
      if (!text.trim()) return {};
      try {
        return JSON.parse(text) as unknown;
      } catch {
        return {};
      }
    } catch (error) {
      if ((error as Error).name === "AbortError") throw error;
    }
  }
  return parseJson ? null : false;
}

export async function listHermesLiveDirect(opts: {
  url: string;
  key: string;
  signal?: AbortSignal;
  profile?: string;
}): Promise<HermesLiveResult> {
  try {
    const [
      apiSkills,
      apiTools,
      apiMcp,
      apiPlugins,
      apiCron,
      apiCronDeliveryTargets,
      apiChannels,
      apiSessions,
      apiPairing,
      apiHooks,
      apiProjects,
      apiCurator,
    ] = await Promise.all([
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/skills", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/tools/toolsets", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/mcp/servers", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/dashboard/plugins/hub", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/cron/jobs", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/cron/delivery-targets", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/messaging/platforms", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/sessions?limit=20&order=recent", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/pairing", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/webhooks", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/projects", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/curator", opts.profile),
        opts.signal,
      ),
    ]);
    return {
      ok: true,
      writable: true,
      owner: false,
      local: false,
      skills: skillsFromApi(apiSkills),
      toolsets: toolsetsFromApi(apiTools),
      plugins: pluginsFromApi(apiPlugins),
      pluginsSupported: apiPlugins !== null,
      mcp: mcpFromApi(apiMcp),
      cron: cronFromApi(apiCron),
      cronDeliveryTargets: cronDeliveryTargetsFromApi(apiCronDeliveryTargets),
      channels: channelsFromApi(apiChannels),
      sessions: sessionsFromApi(apiSessions),
      pairing: pairingList(asRec(apiPairing).pending),
      pairingApproved: pairingList(asRec(apiPairing).approved),
      webhooks: webhooksFromApi(apiHooks),
      projects: projectsFromApi(apiProjects),
      curator: curatorFromApi(apiCurator),
    } satisfies HermesLive;
  } catch {
    return { ok: false, error: "Couldn’t read Hermes status." };
  }
}

export async function readHermesProfilesDirect(opts: {
  url: string;
  key: string;
  signal?: AbortSignal;
}): Promise<HermesProfilesResult> {
  try {
    const [listed, activeRaw] = await Promise.all([
      dashboardGet(opts.url, opts.key, "/api/profiles", opts.signal),
      dashboardGet(opts.url, opts.key, "/api/profiles/active", opts.signal),
    ]);
    const profiles = profilesFromApi(listed);
    if (!profiles.length) {
      return { ok: false, error: "Hermes didn’t return any profiles." };
    }
    const activeRecord = asRec(activeRaw);
    const fallback = profiles[0]?.name ?? "default";
    return {
      ok: true,
      state: {
        active: str(activeRecord.active) || fallback,
        current: str(activeRecord.current) || fallback,
        profiles,
      },
    };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes profiles." };
  }
}

export async function readHermesProfileSoulDirect(opts: {
  url: string;
  key: string;
  name: string;
  signal?: AbortSignal;
}): Promise<HermesProfileSoulResult> {
  try {
    const raw = await dashboardGet(
      opts.url,
      opts.key,
      `/api/profiles/${encodeURIComponent(opts.name)}/soul`,
      opts.signal,
    );
    if (!raw) return { ok: false, error: "Couldn’t read this profile’s SOUL." };
    const record = asRec(raw);
    return {
      ok: true,
      content: typeof record.content === "string" ? record.content : "",
      exists: record.exists === true,
    };
  } catch {
    return { ok: false, error: "Couldn’t read this profile’s SOUL." };
  }
}

export async function readHermesToolsetDetailsDirect(opts: {
  url: string;
  key: string;
  name: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesToolsetDetailsResult> {
  try {
    const encoded = encodeURIComponent(opts.name);
    const [config, models] = await Promise.all([
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath(`/api/tools/toolsets/${encoded}/config`, opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath(`/api/tools/toolsets/${encoded}/models`, opts.profile),
        opts.signal,
      ),
    ]);
    if (!config) {
      return {
        ok: false,
        error: "This Hermes can’t configure this toolset here.",
      };
    }
    return {
      ok: true,
      details: toolsetDetailsFromApi(opts.name, config, models),
    };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes toolset." };
  }
}

export async function readHermesSystemToolsDirect(opts: {
  url: string;
  key: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesSystemToolsResult> {
  try {
    const [terminal, computerUse] = await Promise.all([
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/tools/terminal/backends", opts.profile),
        opts.signal,
      ),
      dashboardGet(
        opts.url,
        opts.key,
        profiledPath("/api/tools/computer-use/status", opts.profile),
        opts.signal,
      ),
    ]);
    return {
      ok: true,
      tools: systemToolsFromApi(terminal, computerUse),
    };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes system tools." };
  }
}

export async function readHermesSkillContentDirect(opts: {
  url: string;
  key: string;
  name: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesSkillContentResult> {
  try {
    const raw = await dashboardGet(
      opts.url,
      opts.key,
      profiledPath(
        `/api/skills/content?name=${encodeURIComponent(opts.name)}`,
        opts.profile,
      ),
      opts.signal,
    );
    const record = asRec(raw);
    const content = typeof record.content === "string" ? record.content : null;
    if (content === null) {
      return { ok: false, error: "Couldn’t read this Hermes skill." };
    }
    return { ok: true, name: str(record.name) || opts.name, content };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes skill." };
  }
}

export async function searchHermesSkillsHubDirect(opts: {
  url: string;
  key: string;
  query: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesSkillHubSearchResult> {
  try {
    const raw = await dashboardGet(
      opts.url,
      opts.key,
      profiledPath(
        `/api/skills/hub/search?q=${encodeURIComponent(opts.query)}&source=all&limit=20`,
        opts.profile,
      ),
      opts.signal,
    );
    if (!raw) return { ok: false, error: "Couldn’t search the Skills Hub." };
    return { ok: true, results: skillHubResultsFromApi(raw) };
  } catch {
    return { ok: false, error: "Couldn’t search the Skills Hub." };
  }
}

export async function readHermesActionStatusDirect(opts: {
  url: string;
  key: string;
  name: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesActionStatusResult> {
  try {
    const raw = await dashboardGet(
      opts.url,
      opts.key,
      profiledPath(
        `/api/actions/${encodeURIComponent(opts.name)}/status?lines=200`,
        opts.profile,
      ),
      opts.signal,
    );
    const record = asRec(raw);
    if (typeof record.running !== "boolean") {
      return { ok: false, error: "Couldn’t read the Hermes action." };
    }
    return {
      ok: true,
      action: {
        name: str(record.name) || opts.name,
        running: record.running,
        exitCode:
          typeof record.exit_code === "number" ? record.exit_code : null,
        lines: Array.isArray(record.lines)
          ? record.lines.map(str).filter(Boolean).slice(-200)
          : [],
      },
    };
  } catch {
    return { ok: false, error: "Couldn’t read the Hermes action." };
  }
}

export async function readHermesSessionMessagesDirect(opts: {
  url: string;
  key: string;
  sessionId: string;
  signal?: AbortSignal;
  profile?: string;
}): Promise<HermesSessionMessagesResult> {
  try {
    const raw = await dashboardGet(
      opts.url,
      opts.key,
      profiledPath(
        `/api/sessions/${encodeURIComponent(opts.sessionId)}/messages?limit=50&order=latest`,
        opts.profile,
      ),
      opts.signal,
    );
    if (!raw) return { ok: false, error: "Couldn’t read this Hermes session." };
    return {
      ok: true,
      sessionId: str(asRec(raw).session_id) || opts.sessionId,
      messages: sessionMessagesFromApi(raw),
    };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes session." };
  }
}

export async function readHermesDiagnosticsDirect(opts: {
  url: string;
  key: string;
  signal?: AbortSignal;
}): Promise<HermesDiagnosticsResult> {
  try {
    const raw = await dashboardGet(
      opts.url,
      opts.key,
      "/health/detailed",
      opts.signal,
    );
    return raw
      ? { ok: true, diagnostics: diagnosticsFromApi(raw) }
      : { ok: false, error: "Couldn’t read Hermes diagnostics." };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes diagnostics." };
  }
}

export async function mutateHermesDirect(
  opts: {
    url: string;
    key: string;
    profile?: string;
  } & HermesMutation,
): Promise<HermesMutationResult> {
  try {
    const operation = hermesScopedOperationFor(opts, opts.profile);
    if (
      operation &&
      (opts.action === "skill-install" ||
        opts.action === "skill-uninstall" ||
        opts.action === "skills-update")
    ) {
      const raw = await dashboardSendJson(
        opts.url,
        opts.key,
        operation.path,
        operation.method,
        operation.body,
      );
      const actionName = str(asRec(raw).name);
      return actionName
        ? { ok: true, actionName }
        : { ok: false, error: "Hermes didn’t start the skill action." };
    }
    if (operation && opts.action === "webhook-create") {
      const raw = await dashboardSendJson(
        opts.url,
        opts.key,
        operation.path,
        operation.method,
        operation.body,
      );
      const created = webhookCreationFromApi(raw);
      return created
        ? { ok: true, ...created }
        : { ok: false, error: "Hermes didn’t return the webhook secret." };
    }
    if (operation && opts.action === "channel-test") {
      const raw = await dashboardSendJson(
        opts.url,
        opts.key,
        operation.path,
        operation.method,
        operation.body,
      );
      const channelTest = channelTestFromApi(raw);
      return channelTest
        ? { ok: true, channelTest }
        : { ok: false, error: "Hermes didn’t return a channel test result." };
    }
    const ok = operation
      ? await dashboardSend(
          opts.url,
          opts.key,
          operation.path,
          operation.method,
          operation.body,
        )
      : false;
    return ok
      ? { ok: true }
      : { ok: false, error: "Hermes couldn’t save the change." };
  } catch {
    return { ok: false, error: "Hermes couldn’t save the change." };
  }
}
