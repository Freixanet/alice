import type {
  HermesChannelRow,
  HermesChannelTestResult,
  HermesCronDeliveryTarget,
  HermesCronRow,
  HermesCuratorStatus,
  HermesDiagnostics,
  HermesMcpRow,
  HermesMcpCatalogResult,
  HermesMcpOAuthResult,
  HermesMcpProbeResult,
  HermesMcpTool,
  HermesMcpUsageResult,
  HermesPairingRow,
  HermesProjectRow,
  HermesProfileRow,
  HermesSessionRow,
  HermesSessionMessage,
  HermesSkillRow,
  HermesSkillHubRow,
  HermesToolsetRow,
  HermesToolsetDetails,
  HermesToolProvider,
  HermesPluginRow,
  HermesSystemTools,
  HermesWebhooksState,
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
    "profiles",
    "data",
  ]) {
    if (Array.isArray(rec[key])) return rec[key] as unknown[];
  }
  return [];
}

export function profilesFromApi(raw: unknown): HermesProfileRow[] {
  return asList(raw)
    .map((item) => {
      const rec = asRec(item);
      const name = str(rec.name);
      const skillCount = Number(rec.skill_count);
      return {
        name,
        displayName: str(rec.display_name) || prettyName(name),
        description: str(rec.description),
        descriptionAuto: rec.description_auto === true,
        isDefault: rec.is_default === true || name === "default",
        model: str(rec.model) || undefined,
        provider: str(rec.provider) || undefined,
        skillCount:
          Number.isFinite(skillCount) && skillCount >= 0 ? skillCount : 0,
        hasEnv: rec.has_env === true,
        gatewayRunning: rec.gateway_running === true,
      } satisfies HermesProfileRow;
    })
    .filter((profile) => profile.name)
    .sort((a, b) =>
      a.isDefault === b.isDefault
        ? a.displayName.localeCompare(b.displayName)
        : a.isDefault
          ? -1
          : 1,
    );
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
  const contextFrom = stringList(rec.context_from);
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
    continuity: contextFrom.some(
      (source) => source.trim().toLowerCase() === "self",
    ),
    monitorScript: str(rec.monitor_script) || undefined,
    monitorUrl: str(rec.monitor_url) || undefined,
    reasoningEffort: str(rec.reasoning_effort) || undefined,
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

export function skillHubResultsFromApi(raw: unknown): HermesSkillHubRow[] {
  const source = asRec(raw).results;
  return asList(source)
    .map((item) => {
      const record = asRec(item);
      const identifier = str(record.identifier);
      return {
        identifier,
        name: str(record.name) || identifier,
        description: str(record.description),
        source: str(record.source) || undefined,
        trust: str(record.trust_level) || undefined,
      };
    })
    .filter((item) => item.identifier)
    .slice(0, 50);
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

function computerUsePermission(raw: unknown) {
  if (typeof raw === "boolean") {
    return { status: raw ? "granted" : "not_granted", granted: raw };
  }
  const record = asRec(raw);
  if (!Object.keys(record).length && !str(raw)) return undefined;
  const status = str(record.status) || str(raw) || "unknown";
  return {
    status,
    granted:
      record.granted === true ||
      record.authorized === true ||
      record.ok === true ||
      /^(granted|authorized|ready|ok)$/i.test(status),
    detail:
      str(record.detail) ||
      str(record.message) ||
      str(record.error) ||
      undefined,
  };
}

export function systemToolsFromApi(
  terminalRaw: unknown,
  computerUseRaw: unknown,
): HermesSystemTools {
  const terminal = asRec(terminalRaw);
  const computerUse = asRec(computerUseRaw);
  const terminalSupported = Object.keys(terminal).length > 0;
  const computerUseSupported = Object.keys(computerUse).length > 0;
  return {
    terminal: {
      supported: terminalSupported,
      active: str(terminal.active) || undefined,
      backends: asList(terminal.backends)
        .map((value) => {
          const row = asRec(value);
          const name = str(row.name);
          const rawStatus = str(row.status);
          const status: "ready" | "needs_setup" | "unavailable" =
            rawStatus === "ready" ||
            rawStatus === "needs_setup" ||
            rawStatus === "unavailable"
              ? rawStatus
              : "unavailable";
          return {
            name,
            label: str(row.label) || prettyName(name),
            description: str(row.description),
            active: row.active === true || name === str(terminal.active),
            status,
            detail: str(row.detail) || undefined,
          };
        })
        .filter((backend) => backend.name),
    },
    computerUse: {
      supported: computerUseSupported,
      platform: str(computerUse.platform) || undefined,
      platformSupported: computerUse.platform_supported === true,
      installed: computerUse.installed === true,
      version: str(computerUse.version) || undefined,
      ready: computerUse.ready === true,
      canGrant: computerUse.can_grant === true,
      source: str(computerUse.source) || undefined,
      error: str(computerUse.error) || undefined,
      checks: asList(computerUse.checks)
        .map((value) => {
          const row = asRec(value);
          const name = str(row.name) || str(row.id) || str(row.check);
          const status =
            str(row.status) || (row.ok === true ? "ready" : "failed");
          return {
            name,
            status,
            ok:
              row.ok === true ||
              /^(ready|ok|passed|granted|available)$/i.test(status),
            detail:
              str(row.detail) ||
              str(row.message) ||
              str(row.error) ||
              undefined,
          };
        })
        .filter((check) => check.name),
      accessibility: computerUsePermission(computerUse.accessibility),
      screenRecording: computerUsePermission(computerUse.screen_recording),
      screenRecordingCapturable:
        typeof computerUse.screen_recording_capturable === "boolean"
          ? computerUse.screen_recording_capturable
          : undefined,
    },
  };
}

export function toolsetDetailsFromApi(
  name: string,
  configRaw: unknown,
  modelsRaw: unknown,
): HermesToolsetDetails {
  const config = asRec(configRaw);
  const models = asRec(modelsRaw);
  return {
    name: str(config.name) || name,
    providers: asList(config.providers)
      .map((value) => {
        const row = asRec(value);
        const providerName = str(row.name);
        const rawCapabilities = Array.isArray(row.capabilities)
          ? row.capabilities.map(str)
          : [];
        const status: HermesToolProvider["status"] =
          row.status === "ready" ||
          row.status === "needs_setup" ||
          row.status === "needs_auth" ||
          row.status === "needs_keys"
            ? row.status
            : undefined;
        return {
          name: providerName,
          badge: str(row.badge),
          tag: str(row.tag),
          envVars: asList(row.env_vars)
            .map((envValue) => {
              const env = asRec(envValue);
              const key = str(env.key);
              return {
                key,
                prompt: str(env.prompt),
                url: str(env.url) || undefined,
                isSet: env.is_set === true,
              };
            })
            .filter((env) => env.key),
          postSetup: str(row.post_setup) || undefined,
          active: row.is_active === true,
          status,
          capabilities: rawCapabilities.filter(
            (capability): capability is "search" | "extract" =>
              capability === "search" || capability === "extract",
          ),
        };
      })
      .filter((provider) => provider.name),
    activeProvider: str(config.active_provider) || undefined,
    activeSearchProvider: str(config.active_search_backend) || undefined,
    activeExtractProvider: str(config.active_extract_backend) || undefined,
    models: asList(models.models)
      .map((value) => {
        const row = asRec(value);
        const id = str(row.id);
        return {
          id,
          display: str(row.display) || id,
          speed: str(row.speed),
          strengths: str(row.strengths),
          price: str(row.price),
        };
      })
      .filter((model) => model.id),
    currentModel: str(models.current) || undefined,
    defaultModel: str(models.default) || undefined,
  };
}

export function pluginsFromApi(raw: unknown): HermesPluginRow[] {
  return asList(asRec(raw).plugins)
    .map((value) => {
      const row = asRec(value);
      const name = str(row.name);
      const rawStatus = str(row.runtime_status);
      const status: HermesPluginRow["status"] =
        rawStatus === "enabled" ||
        rawStatus === "disabled" ||
        rawStatus === "inactive"
          ? rawStatus
          : "inactive";
      return {
        id: `plugin:${name}`,
        name,
        version: str(row.version) || undefined,
        description: str(row.description),
        source: str(row.source) || "Hermes",
        enabled: status === "enabled",
        status,
        canRemove: row.can_remove === true,
        canUpdate: row.can_update_git === true,
        authRequired: row.auth_required === true,
        authCommand: str(row.auth_command) || undefined,
      };
    })
    .filter((plugin) => plugin.name);
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

function mcpToolsFromApi(raw: unknown): HermesMcpTool[] {
  const rows = Array.isArray(raw) ? raw : [];
  return rows
    .slice(0, 500)
    .map((item) => {
      const row = asRec(item);
      const name = str(row.name).slice(0, 256);
      const schemaChars = boundedNumber(row.schema_chars, 0, 10_000_000);
      return {
        name,
        description: str(row.description).slice(0, 2_000),
        ...(schemaChars === undefined ? {} : { schemaChars }),
      };
    })
    .filter((tool) => tool.name);
}

export function mcpProbeFromApi(raw: unknown): HermesMcpProbeResult {
  const record = asRec(raw);
  if (record.ok !== true) {
    return {
      ok: false,
      error: str(record.error).slice(0, 2_000) || "MCP server is unavailable.",
    };
  }
  const tools = mcpToolsFromApi(record.tools);
  const schemaTokens = tools.reduce(
    (total, tool) => total + Math.ceil((tool.schemaChars ?? 0) / 4),
    0,
  );
  return {
    ok: true,
    probe: {
      tools,
      prompts: boundedNumber(record.prompts, 0, 1_000_000) ?? 0,
      resources: boundedNumber(record.resources, 0, 1_000_000) ?? 0,
      ...(schemaTokens > 0 ? { schemaTokens } : {}),
    },
  };
}

export function mcpCatalogFromApi(raw: unknown): HermesMcpCatalogResult {
  const record = asRec(raw);
  const entries = (Array.isArray(record.entries) ? record.entries : [])
    .slice(0, 300)
    .map((item) => {
      const row = asRec(item);
      const name = str(row.name).slice(0, 128);
      const requiredEnv = (
        Array.isArray(row.required_env) ? row.required_env : []
      )
        .slice(0, 64)
        .map((value) => {
          const env = asRec(value);
          return {
            name: str(env.name).slice(0, 128),
            prompt: str(env.prompt).slice(0, 500),
            required: env.required !== false,
          };
        })
        .filter((env) => env.name);
      const safeUrl = (value: unknown) => {
        const url = str(value).slice(0, 2_048);
        return /^https?:\/\//i.test(url) ? url : undefined;
      };
      const defaultEnabled = Array.isArray(row.default_enabled)
        ? row.default_enabled.map(str).filter(Boolean).slice(0, 500)
        : undefined;
      return {
        name,
        description: str(row.description).slice(0, 2_000),
        source: safeUrl(row.source),
        transport: str(row.transport).slice(0, 64) || "unknown",
        authType: str(row.auth_type).slice(0, 64) || "none",
        requiredEnv,
        command: str(row.command).slice(0, 1_024) || undefined,
        args: Array.isArray(row.args)
          ? row.args.map(str).filter(Boolean).slice(0, 64)
          : [],
        url: safeUrl(row.url),
        installUrl: safeUrl(row.install_url),
        installRef: str(row.install_ref).slice(0, 256) || undefined,
        bootstrap: Array.isArray(row.bootstrap)
          ? row.bootstrap.map(str).filter(Boolean).slice(0, 64)
          : [],
        ...(defaultEnabled ? { defaultEnabled } : {}),
        postInstall: str(row.post_install).slice(0, 4_000) || undefined,
        needsInstall: row.needs_install === true,
        installed: row.installed === true,
        enabled: row.enabled === true,
      };
    })
    .filter((entry) => entry.name);
  const diagnostics = (
    Array.isArray(record.diagnostics) ? record.diagnostics : []
  )
    .slice(0, 100)
    .map((value) => {
      const row = asRec(value);
      return {
        name: str(row.name).slice(0, 128),
        kind: str(row.kind).slice(0, 64),
        message: str(row.message).slice(0, 2_000),
      };
    });
  return { ok: true, entries, diagnostics };
}

export function mcpOAuthFlowFromApi(raw: unknown): HermesMcpOAuthResult {
  const record = asRec(raw);
  const flowId = str(record.flow_id).slice(0, 256);
  const serverName = str(record.server_name).slice(0, 128);
  const status = str(record.status);
  if (
    !flowId ||
    !serverName ||
    !["starting", "authorization_required", "approved", "error"].includes(
      status,
    )
  ) {
    return {
      ok: false,
      error: str(record.error).slice(0, 2_000) || "Invalid MCP OAuth response.",
    };
  }
  const authorizationUrl = str(record.authorization_url).slice(0, 2_048);
  return {
    ok: true,
    flow: {
      flowId,
      serverName,
      status: status as
        "starting" | "authorization_required" | "approved" | "error",
      ...(/^https?:\/\//i.test(authorizationUrl) ? { authorizationUrl } : {}),
      ...(str(record.error)
        ? { error: str(record.error).slice(0, 2_000) }
        : {}),
      tools: mcpToolsFromApi(record.tools),
    },
  };
}

export function mcpUsageFromApi(raw: unknown): HermesMcpUsageResult {
  const rows = asList(asRec(raw).tools).slice(0, 5_000);
  const calls: Record<string, number> = {};
  for (const value of rows) {
    const row = asRec(value);
    const tool = str(row.tool).slice(0, 512);
    const count = boundedNumber(row.count, 0, Number.MAX_SAFE_INTEGER);
    if (tool && count !== undefined) calls[tool] = count;
  }
  return { ok: true, calls };
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
      const envVars = (Array.isArray(row.env_vars) ? row.env_vars : [])
        .map((value) => {
          const env = asRec(value);
          const key = str(env.key);
          return {
            key,
            required: env.required === true,
            isSet: env.is_set === true,
            redactedValue: str(env.redacted_value) || undefined,
            description: str(env.description),
            prompt: str(env.prompt),
            url: /^https?:\/\//i.test(str(env.url)) ? str(env.url) : undefined,
            isPassword: env.is_password === true,
            advanced: env.advanced === true,
          };
        })
        .filter((env) => /^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(env.key))
        .slice(0, 64);
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
        docsUrl: /^https?:\/\//i.test(str(row.docs_url))
          ? str(row.docs_url)
          : undefined,
        gatewayRunning: row.gateway_running === true,
        envVars,
      };
    })
    .filter((c) => c.id);
}

export function channelTestFromApi(
  raw: unknown,
): HermesChannelTestResult | null {
  const row = asRec(raw);
  const message = str(row.message).slice(0, 2_000);
  if (typeof row.ok !== "boolean" || !message) return null;
  return {
    ok: row.ok,
    state: str(row.state).slice(0, 128) || undefined,
    message,
  };
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

export function webhooksFromApi(raw: unknown): HermesWebhooksState {
  const root = asRec(raw);
  const subscriptions = asList(raw)
    .map((item) => {
      const rec = asRec(item);
      const name = str(rec.name) || str(rec.id);
      const events = Array.isArray(rec.events)
        ? rec.events.map(str).filter(Boolean)
        : [];
      const skills = Array.isArray(rec.skills)
        ? rec.skills.map(str).filter(Boolean)
        : [];
      return {
        name,
        description: str(rec.description),
        events,
        deliver: str(rec.deliver) || "log",
        deliverOnly: rec.deliver_only === true,
        prompt: str(rec.prompt),
        skills,
        createdAt: stamp(rec.created_at) || undefined,
        url: /^https?:\/\//i.test(str(rec.url)) ? str(rec.url) : undefined,
        secretSet: rec.secret_set === true,
        enabled: rec.enabled !== false,
      };
    })
    .filter((w) => w.name);
  return {
    enabled: root.enabled === true,
    baseUrl: /^https?:\/\//i.test(str(root.base_url))
      ? str(root.base_url)
      : undefined,
    subscriptions,
  };
}

export function webhookCreationFromApi(
  raw: unknown,
): { secret: string; url: string } | null {
  const row = asRec(raw);
  const secret = str(row.secret);
  const url = str(row.url);
  if (!secret || secret.length > 512 || !/^https?:\/\//i.test(url)) return null;
  return { secret, url: url.slice(0, 2_048) };
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
  const folders = (Array.isArray(rec.folders) ? rec.folders : [])
    .map((item) => {
      const folder = asRec(item);
      const path = str(folder.path);
      if (!path) return null;
      const label = str(folder.label);
      return {
        path,
        ...(label ? { label } : {}),
        primary:
          folder.is_primary === true ||
          folder.is_primary === 1 ||
          folder.primary === true ||
          folder.primary === 1,
      };
    })
    .filter((folder) => folder !== null);
  const primary = folders.find((folder) => folder.primary) ?? folders[0];
  const boardSlug = str(rec.board_slug) || str(rec.boardSlug) || str(rec.board);
  return {
    id,
    name: str(rec.name) || prettyName(id),
    slug: str(rec.slug) || id,
    description: str(rec.description),
    path: str(rec.primary_path) || str(rec.path) || primary?.path || undefined,
    folders,
    ...(boardSlug ? { boardSlug } : {}),
    active:
      rec.active === true ||
      rec.active === 1 ||
      rec.is_active === true ||
      rec.is_active === 1,
    archived: rec.archived === true || rec.archived === 1,
  };
}

export function projectsFromApi(raw: unknown): HermesProjectRow[] {
  return asList(raw)
    .map(projectFromUnknown)
    .filter((p) => p.id);
}
