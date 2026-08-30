import type {
  Addon,
  Channel,
  Job,
  MemoryItem,
  Skill,
  SkillCategory,
  Tool,
  Toolset,
  Webhook,
} from "./types";

export const WELCOME =
  "Hello. I’m Alice.\n\nOne thing at a time. Connect your Hermes in Connect when you want to talk to the agent.";

export const SKILL_CATEGORIES: { id: SkillCategory; label: string }[] = [
  { id: "core", label: "Core" },
  { id: "dev", label: "Development" },
  { id: "devops", label: "DevOps" },
  { id: "research", label: "Research" },
  { id: "creative", label: "Creative" },
  { id: "productivity", label: "Productivity" },
  { id: "comms", label: "Communications" },
  { id: "mcp", label: "MCP" },
];

export const TOOLSETS: { id: Toolset; label: string }[] = [
  { id: "web", label: "Web" },
  { id: "terminal", label: "Terminal" },
  { id: "file", label: "Files" },
  { id: "browser", label: "Browser" },
  { id: "memory", label: "Memory" },
  { id: "agent", label: "Agent" },
  { id: "automation", label: "Automation" },
  { id: "messaging", label: "Messaging" },
];

export const skills: Skill[] = [
  {
    id: "hermes-core",
    name: "hermes-core",
    title: "Hermes Core",
    description: "This agent’s personality and rules.",
    category: "core",
    trust: "builtin",
    version: "1.0",
    defaultEnabled: true,
    source: "builtin",
    platforms: ["linux", "macos", "windows"],
  },
  {
    id: "grok",
    name: "grok",
    title: "Grok",
    description: "Use Grok when you need an xAI model.",
    category: "core",
    trust: "official",
    version: "1.0",
    defaultEnabled: true,
    source: "official",
    platforms: ["linux", "macos", "windows"],
  },
  {
    id: "docker-management",
    name: "docker-management",
    title: "Docker",
    description: "Containers, images, and compose without leaving the chat.",
    category: "devops",
    trust: "official",
    version: "0.4",
    defaultEnabled: false,
    source: "nous",
    platforms: ["linux", "macos"],
  },
  {
    id: "code-review",
    name: "code-review",
    title: "Code review",
    description: "Review diffs with judgment, not theater.",
    category: "dev",
    trust: "official",
    version: "0.3",
    defaultEnabled: false,
    source: "nous",
    platforms: ["linux", "macos", "windows"],
  },
  {
    id: "research-brief",
    name: "research-brief",
    title: "Research brief",
    description:
      "Summarize sources and make clear what’s fact and what’s hypothesis.",
    category: "research",
    trust: "trusted",
    version: "0.2",
    defaultEnabled: false,
    source: "community",
    platforms: ["linux", "macos", "windows"],
  },
];

export const tools: Tool[] = [
  {
    id: "web_search",
    name: "web_search",
    description: "Search the web when local context isn’t enough.",
    toolset: "web",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "memory",
    name: "memory",
    description: "Read and write persistent memories.",
    toolset: "memory",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "terminal",
    name: "terminal",
    description: "Run commands on the Hermes machine.",
    toolset: "terminal",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "read_file",
    name: "read_file",
    description: "Read files from the workspace.",
    toolset: "file",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "browser",
    name: "browser",
    description: "Browse pages when you need to see, not just search.",
    toolset: "browser",
    core: false,
    defaultEnabled: false,
  },
];

export const addons: Addon[] = [
  {
    id: "desktop-hermes",
    name: "Hermes Desktop",
    description: "Desktop plugin for notifications and local files.",
    kind: "plugin",
    trust: "official",
    defaultEnabled: false,
    version: "0.8",
  },
  {
    id: "mcp-github",
    name: "GitHub MCP",
    description: "Issues, PRs, and repos through MCP.",
    kind: "mcp",
    trust: "official",
    defaultEnabled: false,
    version: "1.2",
  },
  {
    id: "bundle-ops",
    name: "Ops bundle",
    description: "Skill pack for running a small server.",
    kind: "bundle",
    trust: "trusted",
    defaultEnabled: false,
    version: "0.1",
  },
];

export const channels: Channel[] = [
  {
    id: "telegram",
    name: "Telegram",
    description: "Talk to Hermes from your phone.",
    defaultStatus: "off",
  },
  {
    id: "slack",
    name: "Slack",
    description: "One channel, not the whole company.",
    defaultStatus: "off",
  },
];

export const memories: MemoryItem[] = [
  {
    id: "m1",
    kind: "preference",
    title: "Tone",
    body: "Plain English, second person, short sentences. No emojis.",
    updatedAt: Date.now() - 1000 * 60 * 60 * 20,
    pinned: true,
  },
  {
    id: "m2",
    kind: "project",
    title: "Alice",
    body: "Local cockpit for Hermes Agent. The key does not live in the repo.",
    updatedAt: Date.now() - 1000 * 60 * 40,
  },
];

export const jobs: Job[] = [
  {
    id: "j1",
    name: "Daily digest",
    schedule: "every day at 9:00",
    nextRun: "tomorrow 9:00",
    status: "paused",
  },
];

export const webhooks: Webhook[] = [
  {
    id: "h1",
    path: "/hooks/deploy",
    event: "deploy.ok",
    enabled: false,
  },
];
