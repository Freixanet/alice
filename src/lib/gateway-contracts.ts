export type GatewayMode = "direct" | "proxy";

export type GatewayPlace = "cloud" | "mac" | "device";

export type GatewayStatus = "idle" | "checking" | "live" | "down";

export const HERMES_CURRENT_STABLE = "0.20.6";
export const HERMES_PREVIOUS_STABLE = "0.20.5";

export type HermesCompatibility = "current" | "previous" | "unknown";

export type HermesCapability =
  | "chat.streaming"
  | "chat.multimodal"
  | "chat.tools"
  | "chat.approvals"
  | "chat.cancel"
  | "models"
  | "skills"
  | "toolsets"
  | "mcp"
  | "plugins"
  | "cron"
  | "projects"
  | "memory"
  | "sessions"
  | "profiles"
  | "channels"
  | "pairing"
  | "webhooks"
  | "curator"
  | "diagnostics"
  | "delegation"
  | "code_execution";

export type HermesCapabilityManifest = {
  version: string | null;
  compatibility: HermesCompatibility;
  capabilities: Partial<Record<HermesCapability, boolean>>;
  advertised: string[];
};

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
  manifest?: HermesCapabilityManifest;
};

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
      manifest?: HermesCapabilityManifest;
      mode: GatewayMode;
    }
  | { ok: false; code: ProbeCode; error: string };

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

const CAPABILITY_ALIASES: Record<string, HermesCapability> = {
  streaming: "chat.streaming",
  stream: "chat.streaming",
  multimodal: "chat.multimodal",
  vision: "chat.multimodal",
  tools: "chat.tools",
  tool_calls: "chat.tools",
  approvals: "chat.approvals",
  cancellation: "chat.cancel",
  cancel: "chat.cancel",
  models: "models",
  skills: "skills",
  toolsets: "toolsets",
  mcp: "mcp",
  plugins: "plugins",
  cron: "cron",
  cronjob: "cron",
  projects: "projects",
  kanban: "projects",
  memory: "memory",
  sessions: "sessions",
  profiles: "profiles",
  channels: "channels",
  pairing: "pairing",
  webhooks: "webhooks",
  curator: "curator",
  diagnostics: "diagnostics",
  delegation: "delegation",
  delegate_task: "delegation",
  code_execution: "code_execution",
  execute_code: "code_execution",
};

export function parseHermesCapabilityManifest(
  value: unknown,
): HermesCapabilityManifest {
  const record = asRecord(value);
  const version = firstString(
    record?.version,
    record?.hermes_version,
    record?.agent_version,
  );
  const advertised = collectAdvertised(record).slice(0, 256);
  const capabilities: Partial<Record<HermesCapability, boolean>> = {};
  for (const raw of advertised) {
    const normalized = raw.toLowerCase().replace(/[\s.-]+/g, "_");
    const known = CAPABILITY_ALIASES[normalized];
    if (known) capabilities[known] = true;
  }
  return {
    version,
    compatibility: compatibilityForVersion(version),
    capabilities,
    advertised,
  };
}

function compatibilityForVersion(version: string | null): HermesCompatibility {
  if (!version) return "unknown";
  const normalized = /^v?(\d+\.\d+\.\d+)/.exec(version)?.[1];
  if (normalized === HERMES_CURRENT_STABLE) return "current";
  if (normalized === HERMES_PREVIOUS_STABLE) return "previous";
  return "unknown";
}

function collectAdvertised(record: Record<string, unknown> | null): string[] {
  if (!record) return [];
  const values: string[] = [];
  for (const key of ["capabilities", "features", "toolsets"]) {
    const raw = record[key];
    if (Array.isArray(raw)) {
      for (const item of raw) if (typeof item === "string") values.push(item);
    } else {
      const nested = asRecord(raw);
      if (nested) {
        for (const [name, enabled] of Object.entries(nested)) {
          if (enabled === true) values.push(name);
        }
      }
    }
  }
  return [...new Set(values)];
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
