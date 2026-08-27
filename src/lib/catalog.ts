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
  "Hola. Soy Alice.\n\nUna cosa cada vez. Conecta tu Hermes en Conectar cuando quieras hablar con el agente.";

export const SKILL_CATEGORIES: { id: SkillCategory; label: string }[] = [
  { id: "core", label: "Núcleo" },
  { id: "dev", label: "Desarrollo" },
  { id: "devops", label: "DevOps" },
  { id: "research", label: "Investigación" },
  { id: "creative", label: "Creativo" },
  { id: "productivity", label: "Productividad" },
  { id: "comms", label: "Comunicación" },
  { id: "mcp", label: "MCP" },
];

export const TOOLSETS: { id: Toolset; label: string }[] = [
  { id: "web", label: "Web" },
  { id: "terminal", label: "Terminal" },
  { id: "file", label: "Archivos" },
  { id: "browser", label: "Navegador" },
  { id: "memory", label: "Memoria" },
  { id: "agent", label: "Agente" },
  { id: "automation", label: "Automatización" },
  { id: "messaging", label: "Mensajería" },
];

export const skills: Skill[] = [
  {
    id: "hermes-core",
    name: "hermes-core",
    title: "Hermes Core",
    description: "La personalidad y las reglas de este agente.",
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
    description: "Usa Grok cuando haga falta un modelo de xAI.",
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
    description: "Contenedores, imágenes y compose sin salir del chat.",
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
    description: "Revisa diffs con criterio, no con teatro.",
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
    description: "Resume fuentes y deja claro qué es hecho y qué es hipótesis.",
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
    description: "Busca en la web cuando el contexto local no basta.",
    toolset: "web",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "memory",
    name: "memory",
    description: "Lee y escribe recuerdos persistentes.",
    toolset: "memory",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "terminal",
    name: "terminal",
    description: "Ejecuta comandos en la máquina de Hermes.",
    toolset: "terminal",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "read_file",
    name: "read_file",
    description: "Lee archivos del workspace.",
    toolset: "file",
    core: true,
    defaultEnabled: true,
  },
  {
    id: "browser",
    name: "browser",
    description: "Navega páginas cuando hace falta ver, no solo buscar.",
    toolset: "browser",
    core: false,
    defaultEnabled: false,
  },
];

export const addons: Addon[] = [
  {
    id: "desktop-hermes",
    name: "Hermes Desktop",
    description: "Plugin del escritorio para notificaciones y archivos locales.",
    kind: "plugin",
    trust: "official",
    defaultEnabled: false,
    version: "0.8",
  },
  {
    id: "mcp-github",
    name: "GitHub MCP",
    description: "Issues, PRs y repos a través de MCP.",
    kind: "mcp",
    trust: "official",
    defaultEnabled: false,
    version: "1.2",
  },
  {
    id: "bundle-ops",
    name: "Ops bundle",
    description: "Paquete de skills para operar un servidor pequeño.",
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
    description: "Habla con Hermes desde el teléfono.",
    defaultStatus: "off",
  },
  {
    id: "slack",
    name: "Slack",
    description: "Un canal, no toda la empresa.",
    defaultStatus: "off",
  },
];

export const memories: MemoryItem[] = [
  {
    id: "m1",
    kind: "preference",
    title: "Tono",
    body: "Español de España, de tú, frases cortas. Sin emojis.",
    updatedAt: Date.now() - 1000 * 60 * 60 * 20,
    pinned: true,
  },
  {
    id: "m2",
    kind: "project",
    title: "Alice",
    body: "Cockpit local para el Hermes Agent. La clave no vive en el repo.",
    updatedAt: Date.now() - 1000 * 60 * 40,
  },
];

export const jobs: Job[] = [
  {
    id: "j1",
    name: "Resumen diario",
    schedule: "cada día a las 9:00",
    nextRun: "mañana 9:00",
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
