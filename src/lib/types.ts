export type Trust = "builtin" | "official" | "trusted" | "community";

export type SkillCategory =
  | "core"
  | "dev"
  | "devops"
  | "research"
  | "creative"
  | "finance"
  | "mlops"
  | "comms"
  | "health"
  | "mcp"
  | "productivity";

export type Toolset =
  | "web"
  | "terminal"
  | "file"
  | "browser"
  | "vision"
  | "media"
  | "agent"
  | "memory"
  | "automation"
  | "messaging"
  | "desktop"
  | "home";

export type AddonKind = "plugin" | "mcp" | "bundle";

export type ChannelStatus = "connected" | "paused" | "off";

export type MemoryKind =
  "preference" | "project" | "procedure" | "person" | "fact";

export type JobStatus = "active" | "paused" | "ran";

export type ApprovalKind = "skill" | "tool" | "channel";

export interface Skill {
  id: string;
  name: string;
  title: string;
  description: string;
  category: SkillCategory;
  trust: Trust;
  version: string;
  defaultEnabled: boolean;
  source: string;
  platforms: Array<"linux" | "macos" | "windows">;
}

export interface Tool {
  id: string;
  name: string;
  description: string;
  toolset: Toolset;
  core: boolean;
  defaultEnabled: boolean;
}

export interface Addon {
  id: string;
  name: string;
  description: string;
  kind: AddonKind;
  trust: Trust;
  defaultEnabled: boolean;
  version: string;
}

export interface Channel {
  id: string;
  name: string;
  description: string;
  defaultStatus: ChannelStatus;
}

export interface MemoryItem {
  id: string;
  kind: MemoryKind;
  title: string;
  body: string;
  updatedAt: number;
  pinned?: boolean;
}

export interface Job {
  id: string;
  name: string;
  schedule: string;
  nextRun: string;
  status: JobStatus;
  lastRun?: string;
}

export interface Webhook {
  id: string;
  path: string;
  event: string;
  enabled: boolean;
}

export interface Backend {
  id: string;
  name: string;
  description: string;
  active: boolean;
}

export interface Attachment {
  id: string;
  name: string;
  mime: string;
  kind: "image" | "file";
  dataUrl?: string;
}

export interface Message {
  id: string;
  role: "user" | "assistant";
  content: string;
  createdAt: number;
  pending?: boolean;
  error?: string;
  /** Why the model refused, when the failure was a quota or rate limit. */
  errorLimit?: import("./model-limit").ModelLimit;
  incomplete?: boolean;
  runId?: string;
  runStatus?: import("./gateway-contracts").HermesRunStatus;
  approval?: {
    title: string;
    detail?: string;
    command?: string;
    choices: import("./gateway-contracts").HermesApprovalChoice[];
    resolving?: boolean;
    error?: string;
  };
  attachments?: Attachment[];
  tools?: Array<{
    id: string;
    callId?: string;
    name: string;
    status: "start" | "done";
    detail?: string;
  }>;
}

type OptionalKeys<T> = {
  [K in keyof T]-?: object extends Pick<T, K> ? K : never;
}[keyof T];

/**
 * A message update may explicitly clear optional state while required fields
 * must always retain a concrete value.
 */
export type MessagePatch = {
  [K in keyof Message]?: K extends OptionalKeys<Message>
    ? Message[K] | undefined
    : Message[K];
};

export interface Conversation {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: Message[];
  pinned?: boolean;
  hermesSessionId?: string;
  /** Profile that owns this Hermes session. Never inherit a later UI selection. */
  hermesProfile?: string;
}

export interface Approval {
  id: string;
  kind: ApprovalKind;
  title: string;
  detail: string;
  targetId: string;
}
