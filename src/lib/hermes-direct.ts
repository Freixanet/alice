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
import { classifyModelLimit } from "./model-limit";
import { withDiscoveredManagement } from "./hermes-management-probe";
import {
  parseHermesCapabilityManifest,
  type HermesCapabilityManifest,
} from "./gateway-contracts";
import {
  hermesCronCreateFollowUpFor,
  hermesScopedOperationFor,
  type HermesMutation,
} from "./hermes-operations";
import type {
  HermesActionStatusResult,
  HermesDiagnosticsResult,
  HermesInsightsResult,
  HermesLive,
  HermesLiveResult,
  HermesMutationResult,
  HermesMcpCatalogResult,
  HermesMcpOAuthResult,
  HermesMcpProbeResult,
  HermesMcpUsageResult,
  HermesProfileSoulResult,
  HermesProfilesResult,
  HermesSessionMessagesResult,
  HermesSkillContentResult,
  HermesSkillHubSearchResult,
  HermesSystemToolsResult,
  HermesToolsetDetailsResult,
} from "./hermes-live-types";
import { insightsFromApi } from "./hermes-insights";
import {
  hermesGatewayRpcDirect,
  roomFromRpc,
  roomLogFromRpc,
  roomsFromRpc,
  type HermesRoomMutationResult,
  type HermesRoomLogResult,
  type HermesRoomsResult,
} from "./hermes-groups";
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
  mcpCatalogFromApi,
  mcpOAuthFlowFromApi,
  mcpProbeFromApi,
  mcpUsageFromApi,
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
import { resolveChatModelFallback } from "./model-fallback";
import { isHermesSelfUpdateIntent } from "./hermes-update-intent";
import { whenDefined } from "./exact-optional";

const FAIL = "Couldn’t connect.";

/**
 * Best-effort read of a Hermes error body. Returns "" when there is nothing
 * usable, so the caller falls back to its own wording rather than showing a
 * fragment of HTML or an empty string.
 */

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
      ...whenDefined("signal", opts?.signal),
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
      ...whenDefined("signal", opts.signal),
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
        ...whenDefined("currentProvider", provider),
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

    // Same discovery as the proxy: both transports must agree on what the
    // connected Hermes can do. From the browser a management path may also be
    // blocked by CORS, which reads as "not supported" and is equally correct.
    manifest = await withDiscoveredManagement(manifest, async (path) => {
      try {
        const res = await fetch(`${base}${path}`, {
          headers: hdrs,
          signal: ctrl,
          cache: "no-store",
          redirect: "manual",
        });
        return { ok: res.ok, status: res.status };
      } catch {
        return { ok: false, status: 0 };
      }
    });

    if (opts.save) setDeviceSessionKey(token);
    return {
      ok: true,
      model,
      models,
      ...whenDefined("provider", provider),
      ...whenDefined("platform", platform),
      ...whenDefined("skills", skills),
      ...whenDefined("manifest", manifest),
      mode: "direct",
    };
  } catch (e) {
    if (e instanceof GatewayError)
      return { ok: false, code: e.code, error: e.message };
    return corsFail();
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
      ...whenDefined("conversationId", opts.conversationId),
      ...whenDefined("model", opts.model),
      ...whenDefined("provider", opts.provider),
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
    ...whenDefined("conversationId", opts.conversationId),
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
      ...whenDefined("resolveAll", opts.resolveAll),
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
        ...whenDefined("currentModel", acc.currentModel),
        ...whenDefined("currentProvider", acc.currentProvider),
      },
      {
        refresh: Boolean(opts.refresh),
        ...whenDefined("profile", opts.profile),
      },
    );
    return {
      ok: true,
      models: extra.models,
      ...whenDefined("currentModel", extra.currentModel),
      ...whenDefined("currentProvider", extra.currentProvider),
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
  timeoutMs = 8_000,
): Promise<unknown> {
  const token = assertGatewayKey(key);
  const hdrs = headers(token);
  for (const apiBase of bases(url)) {
    try {
      const ctrl = signal
        ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)])
        : AbortSignal.timeout(timeoutMs);
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
  options?: { signal?: AbortSignal; timeoutMs?: number },
): Promise<unknown> {
  return dashboardMutate(url, key, path, method, body, true, options);
}

async function dashboardMutate(
  url: string,
  key: string,
  path: string,
  method: string,
  body: unknown,
  parseJson: false,
  options?: { signal?: AbortSignal; timeoutMs?: number },
): Promise<boolean>;
async function dashboardMutate(
  url: string,
  key: string,
  path: string,
  method: string,
  body: unknown,
  parseJson: true,
  options?: { signal?: AbortSignal; timeoutMs?: number },
): Promise<unknown>;
async function dashboardMutate(
  url: string,
  key: string,
  path: string,
  method: string,
  body: unknown,
  parseJson: boolean,
  options?: { signal?: AbortSignal; timeoutMs?: number },
): Promise<boolean | unknown> {
  const token = assertGatewayKey(key);
  const timeout = AbortSignal.timeout(options?.timeoutMs ?? 12_000);
  const ctrl = options?.signal
    ? AbortSignal.any([options.signal, timeout])
    : timeout;
  const hdrs = headers(token, { "Content-Type": "application/json" });
  for (const apiBase of bases(url)) {
    try {
      const res = await fetch(`${apiBase}${path}`, {
        method,
        headers: hdrs,
        signal: ctrl,
        cache: "no-store",
        redirect: "manual",
        ...whenDefined(
          "body",
          body === undefined ? undefined : JSON.stringify(body),
        ),
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
      if (options?.signal?.aborted) throw error;
      if ((error as Error).name === "AbortError") throw error;
    }
  }
  return parseJson ? null : false;
}

export async function readHermesMcpCatalogDirect(opts: {
  url: string;
  key: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesMcpCatalogResult> {
  const raw = await dashboardGet(
    opts.url,
    opts.key,
    profiledPath("/api/mcp/catalog", opts.profile),
    opts.signal,
    12_000,
  );
  return raw
    ? mcpCatalogFromApi(raw)
    : { ok: false, error: "Couldn’t read the MCP catalog." };
}

export async function testHermesMcpServerDirect(opts: {
  url: string;
  key: string;
  name: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesMcpProbeResult> {
  const raw = await dashboardSendJson(
    opts.url,
    opts.key,
    profiledPath(
      `/api/mcp/servers/${encodeURIComponent(opts.name)}/test`,
      opts.profile,
    ),
    "POST",
    undefined,
    { ...whenDefined("signal", opts.signal), timeoutMs: 60_000 },
  );
  return raw
    ? mcpProbeFromApi(raw)
    : { ok: false, error: "Couldn’t test this MCP server." };
}

export async function startHermesMcpOAuthDirect(opts: {
  url: string;
  key: string;
  name: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesMcpOAuthResult> {
  const raw = await dashboardSendJson(
    opts.url,
    opts.key,
    profiledPath(
      `/api/mcp/servers/${encodeURIComponent(opts.name)}/auth`,
      opts.profile,
    ),
    "POST",
    undefined,
    { ...whenDefined("signal", opts.signal), timeoutMs: 45_000 },
  );
  return raw
    ? mcpOAuthFlowFromApi(raw)
    : { ok: false, error: "Couldn’t start MCP authorization." };
}

export async function readHermesMcpOAuthDirect(opts: {
  url: string;
  key: string;
  flowId: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesMcpOAuthResult> {
  const raw = await dashboardGet(
    opts.url,
    opts.key,
    profiledPath(
      `/api/mcp/oauth/flows/${encodeURIComponent(opts.flowId)}`,
      opts.profile,
    ),
    opts.signal,
  );
  return raw
    ? mcpOAuthFlowFromApi(raw)
    : { ok: false, error: "Couldn’t read MCP authorization." };
}

export async function readHermesMcpUsageDirect(opts: {
  url: string;
  key: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesMcpUsageResult> {
  const raw = await dashboardGet(
    opts.url,
    opts.key,
    profiledPath("/api/analytics/usage?days=30", opts.profile),
    opts.signal,
    12_000,
  );
  return raw
    ? mcpUsageFromApi(raw)
    : { ok: false, error: "Couldn’t read MCP usage." };
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

export async function readHermesInsightsDirect(opts: {
  url: string;
  key: string;
  days: number;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesInsightsResult> {
  try {
    const params = new URLSearchParams({ days: String(opts.days) });
    if (opts.profile) params.set("profile", opts.profile);
    const raw = await dashboardGet(
      opts.url,
      opts.key,
      `/api/analytics/usage?${params.toString()}`,
      opts.signal,
    );
    const insights = insightsFromApi(raw);
    return insights
      ? { ok: true, insights }
      : { ok: false, error: "Hermes insights are unavailable." };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes insights." };
  }
}

export async function readHermesRoomsDirect(opts: {
  url: string;
  key: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesRoomsResult> {
  try {
    const capabilities = await hermesGatewayRpcDirect({
      ...opts,
      method: "groups.capabilities",
    });
    if (!asRec(capabilities)) return { ok: true, supported: false, rooms: [] };
    const raw = await hermesGatewayRpcDirect({
      ...opts,
      method: "groups.list",
      params: { limit: 100, offset: 0 },
    });
    return { ok: true, supported: true, rooms: roomsFromRpc(raw) };
  } catch {
    return { ok: true, supported: false, rooms: [] };
  }
}

export async function createHermesRoomDirect(opts: {
  url: string;
  key: string;
  roomId: string;
  name: string;
  members: string[];
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesRoomMutationResult> {
  try {
    const raw = await hermesGatewayRpcDirect({
      ...opts,
      method: "groups.create",
      params: {
        room_id: opts.roomId,
        name: opts.name,
        members: opts.members.map((profile) => ({
          member_id: profile,
          profile,
          handle: `agent-${profile}`,
        })),
      },
    });
    const room = roomFromRpc(asRec(raw)?.room);
    return room
      ? { ok: true, room }
      : { ok: false, error: "Hermes didn’t create the group chat." };
  } catch {
    return { ok: false, error: "Couldn’t create this Hermes group chat." };
  }
}

export async function sendHermesRoomMessageDirect(opts: {
  url: string;
  key: string;
  roomId: string;
  eventId: string;
  message: string;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesRoomMutationResult> {
  try {
    const raw = await hermesGatewayRpcDirect({
      ...opts,
      method: "groups.send",
      params: {
        room_id: opts.roomId,
        event_id: opts.eventId,
        payload: { text: opts.message, thread_id: opts.eventId },
      },
    });
    return { ok: true, accepted: asRec(raw)?.accepted === true };
  } catch {
    return { ok: false, error: "Couldn’t send this group message." };
  }
}

export async function readHermesRoomLogDirect(opts: {
  url: string;
  key: string;
  roomId: string;
  sinceSeq: number;
  profile?: string;
  signal?: AbortSignal;
}): Promise<HermesRoomLogResult> {
  try {
    const raw = await hermesGatewayRpcDirect({
      ...opts,
      method: "groups.log",
      params: { room_id: opts.roomId, since_seq: opts.sinceSeq, limit: 100 },
    });
    const log = roomLogFromRpc(raw);
    return log
      ? { ok: true, ...log }
      : { ok: false, error: "Hermes returned an invalid group log." };
  } catch {
    return { ok: false, error: "Couldn’t read this group chat." };
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
  connection: {
    url: string;
    key: string;
    profile?: string;
  },
  mutation: HermesMutation,
): Promise<HermesMutationResult> {
  try {
    const operation = hermesScopedOperationFor(mutation, connection.profile);
    if (operation && mutation.action === "cron-create") {
      const raw = await dashboardSendJson(
        connection.url,
        connection.key,
        operation.path,
        operation.method,
        operation.body,
      );
      const jobId = str(asRec(raw).id);
      if (!jobId) {
        return { ok: false, error: "Hermes didn’t return the new job." };
      }
      const followUp = hermesCronCreateFollowUpFor(
        mutation,
        jobId,
        connection.profile,
      );
      if (
        followUp &&
        !(await dashboardSend(
          connection.url,
          connection.key,
          followUp.path,
          followUp.method,
          followUp.body,
        ))
      ) {
        await dashboardSend(
          connection.url,
          connection.key,
          profiledPath(
            `/api/cron/jobs/${encodeURIComponent(jobId)}`,
            connection.profile,
          ),
          "DELETE",
        );
        return {
          ok: false,
          error: "Hermes couldn’t apply the Pantheon job options.",
        };
      }
      return { ok: true, jobId };
    }
    if (
      operation &&
      (mutation.action === "skill-install" ||
        mutation.action === "skill-uninstall" ||
        mutation.action === "skills-update" ||
        mutation.action === "mcp-catalog-install")
    ) {
      const raw = await dashboardSendJson(
        connection.url,
        connection.key,
        operation.path,
        operation.method,
        operation.body,
      );
      const record = asRec(raw);
      if (mutation.action === "mcp-catalog-install") {
        const actionName = str(record.action);
        return actionName ? { ok: true, actionName } : { ok: true };
      }
      const actionName = str(record.name);
      return actionName
        ? { ok: true, actionName }
        : { ok: false, error: "Hermes didn’t start the skill action." };
    }
    if (operation && mutation.action === "webhook-create") {
      const raw = await dashboardSendJson(
        connection.url,
        connection.key,
        operation.path,
        operation.method,
        operation.body,
      );
      const created = webhookCreationFromApi(raw);
      return created
        ? { ok: true, ...created }
        : { ok: false, error: "Hermes didn’t return the webhook secret." };
    }
    if (operation && mutation.action === "channel-test") {
      const raw = await dashboardSendJson(
        connection.url,
        connection.key,
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
          connection.url,
          connection.key,
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

async function directFailureDetail(response: Response): Promise<string> {
  try {
    const body = (await response.clone().json()) as Record<string, unknown>;
    const detail = body?.detail ?? body?.message ?? body?.error;
    if (typeof detail === "string" && detail.trim()) return detail.trim();
    if (detail && typeof detail === "object" && !Array.isArray(detail)) {
      const nested = detail as Record<string, unknown>;
      if (typeof nested.message === "string" && nested.message.trim()) {
        return nested.message.trim();
      }
    }
  } catch {
    // Non-JSON body: keep the stable fallback wording below.
  }
  return "";
}

async function* streamHermesSelfUpdateDirect(opts: {
  base: string;
  token: string;
  signal: AbortSignal;
}): AsyncGenerator<ChatEvent> {
  const requestHeaders = headers(opts.token, {
    "Content-Type": "application/json",
  });

  try {
    const check = await fetch(
      `${opts.base}/api/hermes/update/check?force=true`,
      {
        headers: requestHeaders,
        signal: opts.signal,
        cache: "no-store",
        redirect: "manual",
      },
    );
    if (check.ok) {
      const body = (await check.json()) as Record<string, unknown>;
      if (body.can_apply === false) {
        const message =
          typeof body.message === "string" && body.message.trim()
            ? body.message.trim()
            : "Esta instalación de Hermes no admite actualizaciones desde Alice.";
        yield { type: "delta", text: message };
        return;
      }
      if (body.update_available === false && body.behind === 0) {
        yield { type: "delta", text: "Hermes ya está actualizado." };
        return;
      }
    }
  } catch (error) {
    if ((error as Error).name === "AbortError") return;
    // The apply endpoint performs its own admission checks, so a failed preview
    // should not block an explicitly requested update.
  }

  try {
    const response = await fetch(`${opts.base}/api/hermes/update`, {
      method: "POST",
      headers: requestHeaders,
      signal: opts.signal,
      cache: "no-store",
      redirect: "manual",
    });
    if (!response.ok) {
      yield {
        type: "error",
        message:
          (await directFailureDetail(response)) ||
          "No pude iniciar la actualización de Hermes.",
      };
      return;
    }
    const body = (await response.json()) as Record<string, unknown>;
    if (body.ok !== true) {
      const message = body.message ?? body.error;
      yield {
        type: "error",
        message:
          typeof message === "string" && message.trim()
            ? message.trim()
            : "Hermes rechazó la actualización.",
      };
      return;
    }
    yield {
      type: "delta",
      text:
        body.already_running === true
          ? "La actualización de Hermes ya estaba en curso. Se está ejecutando en segundo plano."
          : "Actualización de Hermes iniciada en segundo plano. No tienes que mantener este turno abierto; Hermes reiniciará los gateways al terminar y Alice puede desconectarse unos segundos durante el reinicio.",
    };
  } catch (error) {
    if ((error as Error).name === "AbortError") return;
    yield { type: "error", message: CORS_ERROR };
  }
}

/**
 * Direct-browser counterpart of the proxy chat transport. The fallback policy
 * is intentionally delegated to the same shared resolver as the proxy so a
 * device connection cannot silently behave differently from a proxied one.
 */
export async function* streamHermesDirect(opts: {
  url: string;
  key: string;
  messages: Array<{ role: "user" | "assistant"; content: HermesChatContent }>;
  conversationId?: string;
  model?: string;
  provider?: string;
  preferRuns?: boolean;
  runIdempotency?: boolean;
  signal: AbortSignal;
  profile?: string;
}): AsyncGenerator<ChatEvent> {
  const managementBase = normalizeGatewayUrl(opts.url);
  const base = scopeHermesGatewayBase(managementBase, opts.profile);
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  const requestedModel = opts.model?.trim() || "hermes-agent";
  const requestedProvider = opts.provider?.trim() || "";
  const latestUser = [...opts.messages]
    .reverse()
    .find((message) => message.role === "user");

  if (
    latestUser &&
    typeof latestUser.content === "string" &&
    isHermesSelfUpdateIntent(latestUser.content)
  ) {
    yield* streamHermesSelfUpdateDirect({
      base: managementBase,
      token,
      signal,
    });
    return;
  }

  if (opts.preferRuns) {
    try {
      const started = await startHermesRun({
        fetch,
        base,
        token,
        signal,
        messages: opts.messages,
        ...whenDefined("conversationId", opts.conversationId),
        model: requestedModel,
        provider: requestedProvider,
        ...whenDefined("idempotency", opts.runIdempotency),
      });
      if (started.ok) {
        yield* streamStartedHermesRun({
          fetch,
          base,
          token,
          signal,
          run: started.run,
          ...whenDefined("conversationId", opts.conversationId),
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
  let notice: Awaited<ReturnType<typeof resolveChatModelFallback>>["notice"];
  try {
    const first = await post(requestedModel, requestedProvider);
    const resolved = await resolveChatModelFallback({
      requestedModel,
      requestedProvider,
      response: first,
      post,
    });
    upstream = resolved.response;
    notice = resolved.notice;
  } catch (error) {
    if ((error as Error).name === "AbortError") return;
    yield { type: "error", message: CORS_ERROR };
    return;
  }

  if (upstream.status === 401 || upstream.status === 403) {
    yield { type: "error", message: "The key is not correct." };
    return;
  }
  if (!upstream.ok || !upstream.body) {
    const detail = await directFailureDetail(upstream);
    const limit = classifyModelLimit({
      status: upstream.status,
      message: detail,
      retryAfter: upstream.headers.get("retry-after"),
    });
    yield {
      type: "error",
      message: detail || FAIL,
      ...(limit ? { limit } : {}),
    };
    return;
  }

  if (notice) yield { type: "model-fallback", ...notice };

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
