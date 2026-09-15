export type GatewayMode = "direct" | "proxy";

export type GatewayPlace = "cloud" | "mac" | "device";

export type GatewayStatus = "idle" | "checking" | "live" | "down";

export const HERMES_CURRENT_STABLE = "0.21.3";
export const HERMES_PREVIOUS_STABLE = "0.20.6";
// Versions whose 0.21 API contracts have been checked against release sources.
// `current` identifies this compatible contract family, not one exact patch.
export const HERMES_CURRENT_CONTRACT_VERSIONS = [
  HERMES_CURRENT_STABLE,
  "0.21.2",
  "0.21.0",
] as const;

export type HermesCompatibility = "current" | "previous" | "unknown";

export type HermesVersion = Readonly<{
  raw: string | null;
  normalized: string | null;
  compatibility: HermesCompatibility;
}>;

export function parseHermesVersion(value: unknown): HermesVersion {
  const raw = firstString(value);
  const normalized = raw
    ? (/^v?(\d+\.\d+\.\d+)(?:$|[-+])/.exec(raw)?.[1] ?? null)
    : null;
  const compatibility: HermesCompatibility =
    HERMES_CURRENT_CONTRACT_VERSIONS.some((version) => version === normalized)
      ? "current"
      : normalized === HERMES_PREVIOUS_STABLE
        ? "previous"
        : "unknown";
  return { raw, normalized, compatibility };
}

export type HermesCapability =
  | "chat.streaming"
  | "chat.multimodal"
  | "chat.tools"
  | "chat.approvals"
  | "chat.cancel"
  | "chat.runs"
  | "chat.run_idempotency"
  | "chat.steer"
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
  | "groups"
  | "peer_rooms"
  | "artifacts"
  | "insights"
  | "browser_control"
  | "channels"
  | "pairing"
  | "webhooks"
  | "curator"
  | "diagnostics"
  | "delegation"
  | "code_execution";

export type HermesCapabilityManifest = {
  /** Exactly what Hermes reported, e.g. "v0.21.0" or "0.21.0-rc1". Display only. */
  version: string | null;
  /** Bare `major.minor.patch`, or null. Compare against this, never `version`. */
  normalizedVersion: string | null;
  compatibility: HermesCompatibility;
  capabilities: Partial<Record<HermesCapability, boolean>>;
  advertised: string[];
};

export function advertisesHermesCapability(
  manifest: HermesCapabilityManifest | undefined,
  capability: string,
): boolean {
  const expected = normalizeCapabilityName(capability);
  return Boolean(
    manifest?.advertised.some(
      (advertised) => normalizeCapabilityName(advertised) === expected,
    ),
  );
}

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
  | {
      type: "run";
      runId: string;
      status: HermesRunStatus;
      output?: string;
    }
  | {
      type: "approval";
      runId: string;
      title: string;
      detail?: string;
      command?: string;
      choices: HermesApprovalChoice[];
    }
  | ({
      type: "model-fallback";
    } & import("./model-fallback").ModelFallbackNotice)
  | {
      type: "error";
      message: string;
      /**
       * Set when the failure was a model limit. Lets the chat say whether
       * waiting helps instead of showing one generic "couldn't reply".
       */
      limit?: import("./model-limit").ModelLimit;
    };

export type HermesRunStatus =
  | "started"
  | "queued"
  | "running"
  | "waiting_for_approval"
  | "stopping"
  | "completed"
  | "failed"
  | "cancelled";

export type HermesApprovalChoice = "once" | "session" | "always" | "deny";

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

const CAPABILITY_ALIASES: Record<string, HermesCapability[]> = {
  streaming: ["chat.streaming"],
  stream: ["chat.streaming"],
  chat_completions_streaming: ["chat.streaming"],
  responses_streaming: ["chat.streaming"],
  run_events_sse: ["chat.streaming"],
  session_chat_streaming: ["sessions", "chat.streaming"],
  multimodal: ["chat.multimodal"],
  vision: ["chat.multimodal"],
  tools: ["chat.tools"],
  tool_calls: ["chat.tools"],
  tool_progress_events: ["chat.tools"],
  approvals: ["chat.approvals"],
  approval_events: [],
  run_approval: [],
  run_approval_response: [],
  cancellation: ["chat.cancel"],
  cancel: ["chat.cancel"],
  run_stop: ["chat.cancel"],
  runs: ["chat.runs"],
  runs_idempotency: ["chat.runs", "chat.run_idempotency"],
  run_submission: [],
  run_status: [],
  responses_api: [],
  run_steer: ["chat.steer"],
  models: ["models"],
  model_options: ["models"],
  skills: ["skills"],
  skills_api: ["skills"],
  toolsets: ["toolsets"],
  mcp: ["mcp"],
  plugins: ["plugins"],
  cron: ["cron"],
  cronjob: ["cron"],
  projects: ["projects"],
  kanban: ["projects"],
  memory: ["memory"],
  sessions: ["sessions"],
  session_resources: ["sessions"],
  session_create: ["sessions"],
  session_update: ["sessions"],
  session_delete: ["sessions"],
  session_messages: ["sessions"],
  session_fork: ["sessions"],
  session_chat: ["sessions"],
  session_chat_stream: ["sessions", "chat.streaming"],
  session_model_lock: ["sessions", "models"],
  profiles: ["profiles"],
  groups: ["groups"],
  group_chat: ["groups"],
  hosted_rooms: ["groups"],
  groups_capabilities: ["groups"],
  bots: ["profiles", "groups"],
  room_link: ["groups", "peer_rooms"],
  peer_rooms: ["groups", "peer_rooms"],
  groups_peer_invite: ["groups", "peer_rooms"],
  artifact_upload: ["artifacts"],
  artifact_download: ["artifacts"],
  artifacts: ["artifacts"],
  analytics: ["insights"],
  analytics_usage: ["insights"],
  analytics_models: ["insights"],
  insights: ["insights"],
  browser_control: ["browser_control"],
  browser_control_register: ["browser_control"],
  browser_control_ws: ["browser_control"],
  channels: ["channels"],
  pairing: ["pairing"],
  webhooks: ["webhooks"],
  curator: ["curator"],
  diagnostics: ["diagnostics"],
  health_detailed: ["diagnostics"],
  delegation: ["delegation"],
  delegate_task: ["delegation"],
  code_execution: ["code_execution"],
  execute_code: ["code_execution"],
};

export function parseHermesCapabilityManifest(
  value: unknown,
): HermesCapabilityManifest {
  const record = asRecord(value);
  const nested = [
    asRecord(record?.server),
    asRecord(record?.build),
    asRecord(record?.info),
    asRecord(record?.agent),
  ];
  const version = parseHermesVersion(
    firstString(
      record?.version,
      record?.hermes_version,
      record?.agent_version,
      record?.app_version,
      record?.server_version,
      ...nested.flatMap((entry) => [entry?.version, entry?.hermes_version]),
    ),
  );
  const advertised = collectAdvertised(record).slice(0, 256);
  const capabilities: Partial<Record<HermesCapability, boolean>> = {};
  for (const raw of advertised) {
    const normalized = normalizeCapabilityName(raw);
    for (const known of CAPABILITY_ALIASES[normalized] ?? []) {
      capabilities[known] = true;
    }
  }
  const normalized = new Set(advertised.map(normalizeCapabilityName));
  if (
    normalized.has("runs") ||
    (normalized.has("run_submission") &&
      normalized.has("run_status") &&
      normalized.has("run_events_sse"))
  ) {
    capabilities["chat.runs"] = true;
  }
  if (
    normalized.has("approvals") ||
    (normalized.has("approval_events") &&
      (normalized.has("run_approval") ||
        normalized.has("run_approval_response")))
  ) {
    capabilities["chat.approvals"] = true;
  }
  return {
    version: version.raw,
    normalizedVersion: version.normalized,
    compatibility: version.compatibility,
    capabilities,
    advertised,
  };
}

function normalizeCapabilityName(value: string): string {
  return value.toLowerCase().replace(/[\s.-]+/g, "_");
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
          if (
            enabled === true ||
            (enabled !== null &&
              typeof enabled === "object" &&
              !Array.isArray(enabled))
          ) {
            values.push(name);
          }
        }
      }
    }
  }
  const endpoints = asRecord(record.endpoints);
  if (endpoints) {
    for (const [name, rawEndpoint] of Object.entries(endpoints)) {
      const endpoint = asRecord(rawEndpoint);
      if (
        endpoint &&
        typeof endpoint.method === "string" &&
        typeof endpoint.path === "string"
      ) {
        values.push(name);
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
