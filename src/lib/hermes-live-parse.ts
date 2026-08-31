import type {
  HermesChannelRow,
  HermesCronDeliveryTarget,
  HermesCronRow,
  HermesCuratorStatus,
  HermesDiagnostics,
  HermesMcpRow,
  HermesPairingRow,
  HermesProjectRow,
  HermesSessionRow,
  HermesSessionMessage,
  HermesSkillRow,
  HermesToolsetRow,
  HermesWebhookRow,
} from "./hermes-live-types";

const SKILL_GROUPS: Record<string, string> = {
  "software-development": "Development",
  productivity: "Productivity",
  research: "Research",
  creative: "Creative",
  github: "GitHub",
  mlops: "MLOps",
  "autonomous-ai-agents": "Agents",
  apple: "Apple",
  email: "Email",
  health: "Health",
  media: "Media",
  "note-taking": "Notes",
  "smart-home": "Home",
  "social-media": "Social",
  "data-science": "Data",
  mcp: "MCP",
  fitness: "Health",
  "hermes-desktop-plugins": "Desktop",
};

export function asRec(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

export function asList(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  const rec = asRec(value);
  for (const key of [
    "skills",
    "toolsets",
    "jobs",
    "servers",
    "platforms",
    "sessions",
    "subscriptions",
    "webhooks",
    "channels",
    "pending",
    "projects",
    "data",
  ]) {
    if (Array.isArray(rec[key])) return rec[key] as unknown[];
  }
  return [];
}

export function str(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function bool(value: unknown, fallback = true): boolean {
  if (typeof value === "boolean") return value;
  return fallback;
}

const PROPER_NAMES: Record<string, string> = {
  whatsapp: "WhatsApp",
  mcp: "MCP",
  cli: "CLI",
  google_chat: "Google Chat",
  homeassistant: "Home Assistant",
  qqbot: "QQ",
};

export function prettyName(id: string): string {
  if (PROPER_NAMES[id]) return PROPER_NAMES[id];
  return id
    .replace(/[_-]+/g, " ")
    .replace(/\b([a-z])/g, (c) => c.toUpperCase());
}

export function groupLabel(group: string): string {
  return SKILL_GROUPS[group] ?? prettyName(group || "otras");
}

export function cronFromUnknown(item: unknown): HermesCronRow {
  const rec = asRec(item);
  const schedule = asRec(rec.schedule);
  const origin = asRec(rec.origin);
  return {
    id: str(rec.id) || str(rec.name),
    name: str(rec.name) || str(rec.id),
    prompt: str(rec.prompt),
    schedule:
      str(rec.schedule_display) ||
      str(schedule.display) ||
      str(schedule.expr) ||
      "",
    deliver: str(rec.deliver) || str(origin.platform) || "local",
    skills: stringList(rec.skills),
    model: str(rec.model) || undefined,
    provider: str(rec.provider) || undefined,
    script: str(rec.script) || undefined,
    workdir: str(rec.workdir) || undefined,
    enabledToolsets: stringList(rec.enabled_toolsets),
    noAgent: rec.no_agent === true,
    enabled: rec.enabled !== false && str(rec.state) !== "paused",
    state: str(rec.state) || (rec.enabled === false ? "paused" : "scheduled"),
    lastStatus: str(rec.last_status) || undefined,
    lastRunAt: str(rec.last_run_at) || undefined,
    nextRunAt: str(rec.next_run_at) || undefined,
    origin: str(origin.platform) || str(rec.deliver) || undefined,
  };
}

export function cronDeliveryTargetsFromApi(
  raw: unknown,
): HermesCronDeliveryTarget[] {
  const rec = asRec(raw);
  const rows = Array.isArray(rec.targets) ? rec.targets : [];
  const targets: HermesCronDeliveryTarget[] = rows
    .map((item) => {
      const row = asRec(item);
      const id = str(row.id);
      return {
        id,
        name: str(row.name) || prettyName(id),
        homeTargetSet: row.home_target_set !== false,
        ...(str(row.home_env_var) ? { homeEnvVar: str(row.home_env_var) } : {}),
      };
    })
    .filter((target) => target.id);
  if (!targets.some((target) => target.id === "local")) {
    targets.unshift({
      id: "local",
      name: "Local (save only)",
      homeTargetSet: true,
    });
  }
  return targets;
}

function stringList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.map(str).filter(Boolean).slice(0, 64)
    : [];
}

export function skillsFromApi(raw: unknown): HermesSkillRow[] {
  return asList(raw)
    .map((item) => {
      const rec = asRec(item);
      const name = str(rec.name) || str(rec.id);
      const group = str(rec.category) || "otras";
      return {
        id: name,
        name,
        title: prettyName(name),
        description: str(rec.description),
        group,
        groupLabel: groupLabel(group),
        enabled: bool(rec.enabled, true),
        provenance: str(rec.provenance) || undefined,
      };
    })
    .filter((s) => s.id);
}

export function toolsetsFromApi(raw: unknown): HermesToolsetRow[] {
  return asList(raw)
    .map((item) => {
      const rec = asRec(item);
      const name = str(rec.name);
      const tools = Array.isArray(rec.tools)
        ? rec.tools.map(str).filter(Boolean)
        : [];
      return {
        id: name,
        name,
        label: str(rec.label) || prettyName(name),
        description: str(rec.description),
        enabled: bool(rec.enabled, false),
        configured:
          typeof rec.configured === "boolean" ? rec.configured : undefined,
        tools,
        platform: str(rec.platform) || undefined,
      };
    })
    .filter((t) => t.id);
}

export function mcpFromApi(raw: unknown): HermesMcpRow[] {
  return asList(raw)
    .map((item) => {
      const rec = asRec(item);
      const name = str(rec.name);
      const url = str(rec.url);
      const command = str(rec.command);
      const auth: HermesMcpRow["auth"] =
        rec.auth === "oauth" || rec.auth === "header" || rec.auth === "none"
          ? rec.auth
          : undefined;
      return {
        id: name,
        name,
        transport: str(rec.transport) || (url ? "http" : "stdio"),
        detail: url || command || name,
        enabled: rec.enabled !== false,
        auth,
      };
    })
    .filter((m) => m.id);
}

export function cronFromApi(raw: unknown): HermesCronRow[] {
  return asList(raw)
    .map(cronFromUnknown)
    .filter((j) => j.id);
}

export function channelsFromApi(raw: unknown): HermesChannelRow[] {
  const rec = asRec(raw);
  const list = Array.isArray(rec.platforms) ? rec.platforms : asList(raw);
  return list
    .map((item) => {
      const row = asRec(item);
      const id = str(row.id) || str(row.name);
      return {
        id,
        name: str(row.name) || prettyName(id),
        enabled: bool(row.enabled, false),
        configured:
          typeof row.configured === "boolean" ? row.configured : undefined,
        state:
          str(row.state) || (bool(row.enabled, false) ? "activo" : "apagado"),
        description: str(row.description) || undefined,
        error: str(row.error_message) || undefined,
      };
    })
    .filter((c) => c.id);
}

function stamp(value: unknown): string {
  if (typeof value === "string" && value.trim()) {
    const n = Number(value);
    if (!Number.isNaN(n) && n > 1_000_000_000) return stamp(n);
    return value.trim();
  }
  if (typeof value !== "number" || !Number.isFinite(value)) return "";
  const ms = value < 1e12 ? value * 1000 : value;
  const d = new Date(ms);
  return Number.isNaN(d.getTime()) ? "" : d.toISOString();
}

export function sessionsFromApi(raw: unknown): HermesSessionRow[] {
  return asList(raw)
    .slice(0, 30)
    .map((item) => {
      const rec = asRec(item);
      const id = str(rec.id) || str(rec.session_id);
      const title = str(rec.title) || str(rec.preview) || id.slice(0, 12);
      const updated =
        stamp(rec.last_active) ||
        stamp(rec.updated_at) ||
        stamp(rec.started_at);
      const messages =
        typeof rec.message_count === "number"
          ? rec.message_count
          : typeof rec.messages === "number"
            ? rec.messages
            : undefined;
      return {
        id,
        title,
        source: str(rec.source) || undefined,
        updatedAt: updated || undefined,
        messages,
        pinned: rec.pinned === true || rec.pinned === 1,
        archived: rec.archived === true || rec.archived === 1,
        unread: rec.unread === true || rec.unread === 1,
      };
    })
    .filter((s) => s.id);
}

export function sessionMessagesFromApi(raw: unknown): HermesSessionMessage[] {
  return asList(raw)
    .slice(-50)
    .map((item, index) => {
      const row = asRec(item);
      const rawRole = str(row.role).toLowerCase();
      const role: HermesSessionMessage["role"] =
        rawRole === "user" ||
        rawRole === "assistant" ||
        rawRole === "system" ||
        rawRole === "tool"
          ? rawRole
          : "unknown";
      return {
        id: str(row.id) || `message-${index}`,
        role,
        content: safeMessageContent(row.content),
        timestamp: stamp(row.timestamp) || undefined,
        toolName: str(row.tool_name) || undefined,
      };
    })
    .filter((message) => message.content || message.toolName);
}

export function diagnosticsFromApi(raw: unknown): HermesDiagnostics {
  const row = asRec(raw);
  const readiness = asRec(row.readiness);
  const platformRows = Object.entries(asRec(row.platforms))
    .slice(0, 32)
    .map(([id, value]) => {
      const platform = asRec(value);
      const primitiveStatus =
        typeof value === "string"
          ? value
          : typeof value === "boolean"
            ? value
              ? "connected"
              : "disconnected"
            : "";
      return {
        id: id.slice(0, 128),
        name: prettyName(id).slice(0, 128),
        status: (
          str(platform.status) ||
          str(platform.state) ||
          primitiveStatus ||
          "unknown"
        ).slice(0, 128),
      };
    });
  const rawAgents = Number(row.active_agents);
  return {
    status: (str(row.status) || str(readiness.status) || "unknown").slice(
      0,
      64,
    ),
    version: str(row.version).slice(0, 64) || undefined,
    gatewayState: str(row.gateway_state).slice(0, 128) || undefined,
    activeAgents: Number.isFinite(rawAgents)
      ? Math.max(0, Math.min(10_000, Math.trunc(rawAgents)))
      : 0,
    busy: row.gateway_busy === true,
    drainable: row.gateway_drainable === true,
    updatedAt: stamp(row.updated_at) || undefined,
    exitReason: str(row.exit_reason).slice(0, 256) || undefined,
    platforms: platformRows,
  };
}

function safeMessageContent(value: unknown): string {
  if (typeof value === "string") return value.slice(0, 4_000);
  if (value === null || value === undefined) return "";
  try {
    return JSON.stringify(value).slice(0, 4_000);
  } catch {
    return "";
  }
}

export function pairingList(value: unknown): HermesPairingRow[] {
  return (Array.isArray(value) ? value : [])
    .map((item) => {
      const row = asRec(item);
      return {
        platform: str(row.platform) || str(row.id),
        code: str(row.code) || undefined,
        requestId: str(row.request_id) || undefined,
        userId: str(row.user_id) || undefined,
        user:
          str(row.user_name) ||
          str(row.user) ||
          str(row.display_name) ||
          str(row.user_id) ||
          undefined,
      };
    })
    .filter((p) => p.platform);
}

export function webhooksFromApi(raw: unknown): HermesWebhookRow[] {
  return asList(raw)
    .map((item) => {
      const rec = asRec(item);
      const name = str(rec.name) || str(rec.id);
      const events = Array.isArray(rec.events)
        ? rec.events.map(str).filter(Boolean)
        : [];
      return {
        name,
        enabled: rec.enabled !== false,
        event:
          events.join(", ") ||
          str(rec.event) ||
          str(rec.path) ||
          str(rec.description) ||
          undefined,
      };
    })
    .filter((w) => w.name);
}

export function curatorFromApi(raw: unknown): HermesCuratorStatus | null {
  const row = asRec(raw);
  if (typeof row.enabled !== "boolean" || typeof row.paused !== "boolean") {
    return null;
  }
  return {
    enabled: row.enabled,
    paused: row.paused,
    intervalHours: boundedNumber(row.interval_hours, 0, 24 * 365),
    lastRunAt: stamp(row.last_run_at) || undefined,
    minIdleHours: boundedNumber(row.min_idle_hours, 0, 24 * 365),
    staleAfterDays: boundedNumber(row.stale_after_days, 0, 365_000),
    archiveAfterDays: boundedNumber(row.archive_after_days, 0, 365_000),
  };
}

function boundedNumber(
  value: unknown,
  minimum: number,
  maximum: number,
): number | undefined {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    value >= minimum &&
    value <= maximum
    ? value
    : undefined;
}

export function projectFromUnknown(item: unknown): HermesProjectRow {
  const rec = asRec(item);
  const id = str(rec.id) || str(rec.slug);
  const folders = Array.isArray(rec.folders) ? rec.folders : [];
  const primary = folders.find((f) => asRec(f).is_primary) ?? folders[0];
  return {
    id,
    name: str(rec.name) || prettyName(id),
    slug: str(rec.slug) || id,
    description: str(rec.description),
    path: str(rec.primary_path) || str(asRec(primary).path) || undefined,
    archived: rec.archived === true || rec.archived === 1,
  };
}

export function projectsFromApi(raw: unknown): HermesProjectRow[] {
  return asList(raw)
    .map(projectFromUnknown)
    .filter((p) => p.id);
}
