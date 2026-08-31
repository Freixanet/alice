import { authHeaders } from "./auth/client";
import type {
  HermesDiagnosticsResult,
  HermesLiveResult,
  HermesSessionMessagesResult,
} from "./hermes-live-types";
import type { HermesMutation } from "./hermes-operations";

export type * from "./hermes-live-types";

export async function listHermesLive(opts?: {
  signal?: AbortSignal;
}): Promise<HermesLiveResult> {
  try {
    const { useHermes } = await import("./store");
    const place = useHermes.getState().gatewayPlace;
    if (place === "device") {
      const { getDeviceSessionKey, listHermesLiveDirect } =
        await import("./hermes-direct");
      const url = useHermes.getState().gatewayUrl;
      const key = getDeviceSessionKey();
      if (!url || !key)
        return { ok: false, error: "Connect your Hermes on this computer." };
      return listHermesLiveDirect({ url, key, signal: opts?.signal });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "live" }),
      signal: opts?.signal,
    });
    const data = (await res.json()) as HermesLiveResult;
    if (data && data.ok) return data;
    const message =
      data &&
      "error" in data &&
      typeof data.error === "string" &&
      data.error.trim()
        ? data.error
        : "Couldn’t read Hermes status.";
    return { ok: false, error: message };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes status." };
  }
}

export async function mutateHermes(
  opts: HermesMutation,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const { useHermes } = await import("./store");
    const place = useHermes.getState().gatewayPlace;
    if (place === "device") {
      const { getDeviceSessionKey, mutateHermesDirect } =
        await import("./hermes-direct");
      const url = useHermes.getState().gatewayUrl;
      const key = getDeviceSessionKey();
      if (!url || !key)
        return { ok: false, error: "Connect your Hermes on this computer." };
      return mutateHermesDirect({ url, key, ...opts });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(opts),
    });
    const data = (await res.json()) as { ok?: boolean; error?: string };
    return { ok: Boolean(data.ok), error: data.error };
  } catch {
    return { ok: false, error: "Hermes couldn’t save the change." };
  }
}

export async function readHermesDiagnostics(opts?: {
  signal?: AbortSignal;
}): Promise<HermesDiagnosticsResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesDiagnosticsDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesDiagnosticsDirect({
        url: state.gatewayUrl,
        key,
        signal: opts?.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "diagnostics" }),
      signal: opts?.signal,
      cache: "no-store",
    });
    const data = (await res.json()) as HermesDiagnosticsResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read Hermes diagnostics.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes diagnostics." };
  }
}

export async function readHermesSessionMessages(opts: {
  sessionId: string;
  signal?: AbortSignal;
}): Promise<HermesSessionMessagesResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesSessionMessagesDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesSessionMessagesDirect({
        url: state.gatewayUrl,
        key,
        sessionId: opts.sessionId,
        signal: opts.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "session-messages",
        sessionId: opts.sessionId,
      }),
      signal: opts.signal,
    });
    const data = (await res.json()) as HermesSessionMessagesResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read this Hermes session.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes session." };
  }
}
