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
  auth?: "none" | "oauth" | "header";
};

export type HermesCronRow = {
  id: string;
  name: string;
  prompt: string;
  schedule: string;
  deliver: string;
  skills: string[];
  model?: string;
  provider?: string;
  script?: string;
  workdir?: string;
  enabledToolsets: string[];
  noAgent: boolean;
  enabled: boolean;
  state: string;
  lastStatus?: string;
  lastRunAt?: string;
  nextRunAt?: string;
  origin?: string;
};

export type HermesCronDeliveryTarget = {
  id: string;
  name: string;
  homeTargetSet: boolean;
  homeEnvVar?: string;
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
  pinned: boolean;
  archived: boolean;
  unread: boolean;
};

export type HermesSessionMessage = {
  id: string;
  role: "user" | "assistant" | "system" | "tool" | "unknown";
  content: string;
  timestamp?: string;
  toolName?: string;
};

export type HermesSessionMessagesResult =
  | {
      ok: true;
      sessionId: string;
      messages: HermesSessionMessage[];
    }
  | { ok: false; error: string };

export type HermesDiagnosticPlatform = {
  id: string;
  name: string;
  status: string;
};

export type HermesDiagnostics = {
  status: string;
  version?: string;
  gatewayState?: string;
  activeAgents: number;
  busy: boolean;
  drainable: boolean;
  updatedAt?: string;
  exitReason?: string;
  platforms: HermesDiagnosticPlatform[];
};

export type HermesDiagnosticsResult =
  { ok: true; diagnostics: HermesDiagnostics } | { ok: false; error: string };

export type HermesPairingRow = {
  platform: string;
  code?: string;
  requestId?: string;
  userId?: string;
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
  description: string;
  events: string[];
  deliver: string;
  deliverOnly: boolean;
  prompt: string;
  skills: string[];
  createdAt?: string;
  url?: string;
  secretSet: boolean;
  enabled: boolean;
};

export type HermesWebhooksState = {
  enabled: boolean;
  baseUrl?: string;
  subscriptions: HermesWebhookRow[];
};

export type HermesMutationResult =
  { ok: true; secret?: string; url?: string } | { ok: false; error: string };

export type HermesCuratorStatus = {
  enabled: boolean;
  paused: boolean;
  intervalHours?: number;
  lastRunAt?: string;
  minIdleHours?: number;
  staleAfterDays?: number;
  archiveAfterDays?: number;
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
  cronDeliveryTargets: HermesCronDeliveryTarget[];
  channels: HermesChannelRow[];
  sessions: HermesSessionRow[];
  pairing: HermesPairingRow[];
  pairingApproved: HermesPairingRow[];
  webhooks: HermesWebhooksState;
  projects: HermesProjectRow[];
  curator: HermesCuratorStatus | null;
};

export type HermesLiveResult = HermesLive | { ok: false; error: string };
