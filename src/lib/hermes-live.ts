import { authHeaders } from "./auth/client";

export type HermesSkillRow = {
  id: string;
  name: string;
  title: string;
  description: string;
  group: string;
  groupLabel: string;
  enabled: boolean;
  provenance?: string;
};

export type HermesToolsetRow = {
  id: string;
  name: string;
  label: string;
  description: string;
  enabled: boolean;
  configured?: boolean;
  tools: string[];
  platform?: string;
};

export type HermesMcpRow = {
  id: string;
  name: string;
  transport: string;
  detail: string;
  enabled: boolean;
};

export type HermesCronRow = {
  id: string;
  name: string;
  schedule: string;
  enabled: boolean;
  state: string;
  lastStatus?: string;
  lastRunAt?: string;
  nextRunAt?: string;
  origin?: string;
};

export type HermesChannelRow = {
  id: string;
  name: string;
  enabled: boolean;
  configured?: boolean;
  state: string;
  description?: string;
  error?: string;
};

export type HermesSessionRow = {
  id: string;
  title: string;
  source?: string;
  updatedAt?: string;
  messages?: number;
};

export type HermesPairingRow = {
  platform: string;
  code?: string;
  user?: string;
};

export type HermesProjectRow = {
  id: string;
  name: string;
  slug: string;
  description: string;
  path?: string;
  archived: boolean;
};

export type HermesWebhookRow = {
  name: string;
  enabled: boolean;
  event?: string;
};

export type HermesLive = {
  ok: true;
  writable: boolean;
  owner: boolean;
  local: boolean;
  skills: HermesSkillRow[];
  toolsets: HermesToolsetRow[];
  mcp: HermesMcpRow[];
  cron: HermesCronRow[];
  channels: HermesChannelRow[];
  sessions: HermesSessionRow[];
  pairing: HermesPairingRow[];
  pairingApproved: HermesPairingRow[];
  webhooks: HermesWebhookRow[];
  projects: HermesProjectRow[];
};

export type HermesLiveResult = HermesLive | { ok: false; error: string };

export async function listHermesLive(opts?: { signal?: AbortSignal }): Promise<HermesLiveResult> {
  try {
    const { useHermes } = await import("./store");
    const place = useHermes.getState().gatewayPlace;
    if (place === "device") {
      const { getDeviceSessionKey, listHermesLiveDirect } = await import("./hermes-direct");
      const url = useHermes.getState().gatewayUrl;
      const key = getDeviceSessionKey();
      if (!url || !key) return { ok: false, error: "Connect your Hermes on this computer." };
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
      data && "error" in data && typeof data.error === "string" && data.error.trim()
        ? data.error
        : "Couldn’t read Hermes status.";
    return { ok: false, error: message };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes status." };
  }
}

export async function mutateHermes(opts: {
  action: "toggle-skill" | "toggle-toolset" | "toggle-mcp" | "cron-pause" | "cron-resume";
  name?: string;
  enabled?: boolean;
  jobId?: string;
}): Promise<{ ok: boolean; error?: string }> {
  try {
    const { useHermes } = await import("./store");
    const place = useHermes.getState().gatewayPlace;
    if (place === "device") {
      const { getDeviceSessionKey, mutateHermesDirect } = await import("./hermes-direct");
      const url = useHermes.getState().gatewayUrl;
      const key = getDeviceSessionKey();
      if (!url || !key) return { ok: false, error: "Connect your Hermes on this computer." };
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
