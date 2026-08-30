import { authHeaders } from "./auth/client";
import {
  friendlyProbeError,
  type GatewayPlace,
  type HermesModelOption,
  type ProbeCode,
  type ProbeResult,
} from "./gateway";
import {
  getDeviceSessionKey,
  listHermesModelsDirect,
  loadSavedDeviceConnection,
  probeHermesDirect,
  saveDeviceConnection,
  setHermesModelDirect,
} from "./hermes-direct";
import { useHermes } from "./store";

type HermesActionResult = ProbeResult & { models?: HermesModelOption[] };

export async function probeGateway(opts: {
  url: string;
  key?: string;
  place: GatewayPlace;
  save?: boolean;
  signal?: AbortSignal;
}): Promise<ProbeResult> {
  if (opts.place === "device") {
    let key = opts.key || getDeviceSessionKey() || "";
    if (!key) {
      const saved = await loadSavedDeviceConnection({
        url: opts.url,
        signal: opts.signal,
      });
      key = saved?.key ?? "";
    }
    if (!key) {
      return {
        ok: false,
        code: "invalid",
        error: "Enter the Hermes key once to reconnect it.",
      };
    }
    const result = await probeHermesDirect({
      url: opts.url,
      key,
      save: opts.save,
      signal: opts.signal,
    });
    if (result.ok && opts.save) {
      const saved = await saveDeviceConnection({
        url: opts.url,
        key,
        signal: opts.signal,
      });
      if (!saved) {
        return {
          ok: false,
          code: "unreachable",
          error: "Hermes connected, but Alice couldn’t remember it. Try again.",
        };
      }
    }
    return result;
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
    const code = (data as { code?: ProbeCode }).code;
    return {
      ok: false,
      code: code ?? "unreachable",
      error: friendlyProbeError(code),
    };
  } catch (error) {
    if ((error as Error).name === "AbortError") {
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
    const { gatewayPlace: place, gatewayUrl: url } = useHermes.getState();
    if (place === "device") {
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

export async function setHermesModel(opts: {
  url: string;
  key?: string;
  place: GatewayPlace;
  model: string;
  provider?: string;
  conversationId?: string;
}): Promise<{ ok: boolean }> {
  if (opts.place === "device") {
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
