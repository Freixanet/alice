import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { localHermesAvailable } from "./auth/owner.server";
import {
  getHermesHomeDir,
  hermesDashboardGet,
  hermesDashboardSend,
} from "./gateway.server";
import type { GatewayPlace } from "./gateway";
import type {
  HermesChannelRow,
  HermesCronRow,
  HermesLive,
  HermesMcpRow,
  HermesPairingRow,
  HermesProjectRow,
  HermesSessionRow,
  HermesSkillRow,
  HermesToolsetRow,
  HermesWebhookRow,
} from "./hermes-live";
import {
  asList,
  asRec,
  channelsFromApi,
  cronFromApi,
  cronFromUnknown,
  groupLabel,
  mcpFromApi,
  pairingList,
  prettyName,
  projectsFromApi,
  sessionsFromApi,
  skillsFromApi,
  str,
  toolsetsFromApi,
  webhooksFromApi,
} from "./hermes-live-parse";

const SKIP_DIRS = new Set([
  "node_modules",
  ".git",
  ".archive",
  "lsp",
  "hermes-agent",
  "dist",
]);

type Gate = {
  url: string;
  key: string;
  place?: GatewayPlace;
  signal?: AbortSignal;
};

async function readUtf8(path: string): Promise<string> {
  try {
    return await readFile(path, "utf8");
  } catch {
    return "";
  }
}

function parseFrontmatter(text: string): { name: string; description: string } {
  if (!text.startsWith("---")) return { name: "", description: "" };
  const end = text.indexOf("\n---", 3);
  if (end < 0) return { name: "", description: "" };
  const block = text.slice(4, end);
  const name = /(?:^|\n)name:\s*["']?([^\n"']+)/.exec(block)?.[1]?.trim() ?? "";
  const folded =
    /(?:^|\n)description:\s*[|>][^\n]*\n((?:[ \t]+[^\n]*\n?)*)/.exec(block);
  if (folded) {
    const description = folded[1]
      .split("\n")
      .map((line) => line.replace(/^[ \t]+/, "").trim())
      .filter(Boolean)
      .join(" ")
      .trim();
    return { name, description };
  }
  const raw = /(?:^|\n)description:\s*(.+)/.exec(block)?.[1]?.trim() ?? "";
  const description = raw.replace(/^["']|["']$/g, "").trim();
  return { name, description };
}

async function walkSkillFiles(
  dir: string,
  acc: string[],
  depth = 0,
): Promise<void> {
  if (depth > 6 || acc.length > 400) return;
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry.name.startsWith(".") && entry.name !== ".hermes") continue;
    if (SKIP_DIRS.has(entry.name)) continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) await walkSkillFiles(path, acc, depth + 1);
    else if (entry.name === "SKILL.md") acc.push(path);
  }
}

async function skillsFromDisk(): Promise<HermesSkillRow[]> {
  const root = join(getHermesHomeDir(), "skills");
  const files: string[] = [];
  await walkSkillFiles(root, files);
  const disabled = new Set(await disabledSkillsFromDisk());
  const out: HermesSkillRow[] = [];
  const seen = new Set<string>();
  for (const file of files) {
    const raw = await readUtf8(file);
    const meta = parseFrontmatter(raw);
    const parts = file.split("/skills/")[1]?.split("/") ?? [];
    const folder =
      parts.length > 2
        ? parts[0]
        : parts[0] === "SKILL.md"
          ? "otras"
          : parts[0];
    const id = meta.name || parts[parts.length - 2] || file;
    if (seen.has(id)) continue;
    seen.add(id);
    let description = meta.description;
    if (!description) {
      for (const line of raw.split("\n")) {
        const t = line.trim();
        if (t && !t.startsWith("#") && !t.startsWith("---")) {
          description = t;
          break;
        }
      }
    }
    out.push({
      id,
      name: id,
      title: prettyName(id),
      description: description.slice(0, 240),
      group: folder || "otras",
      groupLabel: groupLabel(folder || "otras"),
      enabled: !disabled.has(id),
    });
  }
  return out.sort(
    (a, b) =>
      a.groupLabel.localeCompare(b.groupLabel) ||
      a.title.localeCompare(b.title),
  );
}

async function disabledSkillsFromDisk(): Promise<string[]> {
  const cfg = await loadConfigDoc();
  const skills = asRec(cfg.skills);
  const disabled = skills.disabled;
  if (!Array.isArray(disabled)) return [];
  return disabled.map((x) => str(x)).filter(Boolean);
}

async function loadConfigDoc(): Promise<Record<string, unknown>> {
  const file = `${getHermesHomeDir()}/config.yaml`;
  const script = `import json,sys,yaml
cfg=yaml.safe_load(open(sys.argv[1],encoding="utf-8")) or {}
keep=("mcp_servers","platform_toolsets","plugins","skills","platforms","whatsapp","telegram","discord","slack","signal")
print(json.dumps({k:cfg.get(k) for k in keep}))`;
  try {
    const { execFile } = await import("node:child_process");
    const { promisify } = await import("node:util");
    const run = promisify(execFile);
    const { stdout } = await run("python3", ["-c", script, file], {
      timeout: 5000,
    });
    return asRec(JSON.parse(stdout));
  } catch {
    return {};
  }
}

async function toolsetsFromDisk(): Promise<HermesToolsetRow[]> {
  const cfg = await loadConfigDoc();
  const platforms = asRec(cfg.platform_toolsets);
  const cli = Array.isArray(platforms.cli)
    ? platforms.cli.map(str).filter(Boolean)
    : [];
  const enabled = new Set(cli);
  const names = enabled.size ? [...enabled] : ["hermes-cli"];
  return names.map((name) => ({
    id: name,
    name,
    label: prettyName(name),
    description: name.startsWith("hermes-")
      ? "Toolset de Hermes para este canal."
      : "Toolset nativo de Hermes.",
    enabled: true,
    tools: [],
    platform: "cli",
  }));
}

async function mcpFromDisk(): Promise<HermesMcpRow[]> {
  const cfg = await loadConfigDoc();
  const servers = asRec(cfg.mcp_servers);
  return Object.entries(servers).map(([name, raw]) => {
    const rec = asRec(raw);
    const url = str(rec.url);
    const command = str(rec.command);
    return {
      id: name,
      name,
      transport: url ? "http" : command ? "stdio" : "unknown",
      detail: url || command || name,
      enabled: rec.enabled !== false,
    };
  });
}

async function cronFromDisk(): Promise<HermesCronRow[]> {
  const raw = await readUtf8(join(getHermesHomeDir(), "cron", "jobs.json"));
  if (!raw) return [];
  try {
    const data = JSON.parse(raw) as unknown;
    const jobs = asList(data);
    return jobs.map((item) => cronFromUnknown(item)).filter((j) => j.id);
  } catch {
    return [];
  }
}

async function channelsFromDisk(): Promise<HermesChannelRow[]> {
  const cfg = await loadConfigDoc();
  const known = ["whatsapp", "telegram", "discord", "slack", "signal"];
  const seen = new Map<string, HermesChannelRow>();
  for (const id of known) {
    if (!cfg[id] || typeof cfg[id] !== "object" || Array.isArray(cfg[id]))
      continue;
    seen.set(id, {
      id,
      name: prettyName(id),
      enabled: true,
      configured: true,
      state: "en config",
    });
  }
  for (const job of await cronFromDisk()) {
    const id = (job.origin || "").toLowerCase();
    if (!known.includes(id) || seen.has(id)) continue;
    seen.set(id, {
      id,
      name: prettyName(id),
      enabled: true,
      configured: true,
      state: "en tareas",
    });
  }
  return [...seen.values()];
}

async function projectsFromDisk(): Promise<HermesProjectRow[]> {
  const file = join(getHermesHomeDir(), "projects.db");
  const script = `import json,os,sqlite3,sys
path=sys.argv[1]
if not os.path.exists(path):
    print("[]"); raise SystemExit
con=sqlite3.connect(path)
con.row_factory=sqlite3.Row
try:
    rows=con.execute("select id,slug,name,description,primary_path,archived from projects order by created_at asc").fetchall()
except sqlite3.OperationalError:
    print("[]"); raise SystemExit
out=[]
for r in rows:
    folders=[]
    try:
        folders=con.execute("select path,is_primary from project_folders where project_id=?", (r["id"],)).fetchall()
    except sqlite3.OperationalError:
        pass
    primary=r["primary_path"] or next((f["path"] for f in folders if f["is_primary"]), None) or (folders[0]["path"] if folders else None)
    out.append({"id":r["id"],"slug":r["slug"],"name":r["name"],"description":r["description"] or "","primary_path":primary,"archived":bool(r["archived"])})
print(json.dumps(out))`;
  try {
    const { execFile } = await import("node:child_process");
    const { promisify } = await import("node:util");
    const run = promisify(execFile);
    const { stdout } = await run("python3", ["-c", script, file], {
      timeout: 5000,
    });
    return projectsFromApi(JSON.parse(stdout));
  } catch {
    return [];
  }
}

export async function fetchHermesLive(opts?: {
  url?: string;
  key?: string;
  place?: GatewayPlace;
  signal?: AbortSignal;
  local?: boolean;
  owner?: boolean;
}): Promise<HermesLive> {
  const writable = Boolean(opts?.url && opts.key);
  const owner = Boolean(opts?.owner);
  const local = localHermesAvailable();
  const readDisk = owner && local && opts?.local !== false;
  const gate: Gate | null = writable
    ? {
        url: opts!.url!,
        key: opts!.key!,
        place: opts?.place,
        signal: opts?.signal,
      }
    : null;

  const empty = {
    skills: [] as HermesSkillRow[],
    toolsets: [] as HermesToolsetRow[],
    mcp: [] as HermesMcpRow[],
    cron: [] as HermesCronRow[],
    channels: [] as HermesChannelRow[],
    projects: [] as HermesProjectRow[],
  };

  const disk = readDisk
    ? await Promise.all([
        skillsFromDisk(),
        toolsetsFromDisk(),
        mcpFromDisk(),
        cronFromDisk(),
        channelsFromDisk(),
        projectsFromDisk(),
      ]).then(([skills, toolsets, mcp, cron, channels, projects]) => ({
        skills,
        toolsets,
        mcp,
        cron,
        channels,
        projects,
      }))
    : empty;

  let skills = disk.skills;
  let toolsets = disk.toolsets;
  let mcp = disk.mcp;
  let cron = disk.cron;
  let channels = disk.channels;
  let projects = disk.projects;
  let sessions: HermesSessionRow[] = [];
  let pairing: HermesPairingRow[] = [];
  let pairingApproved: HermesPairingRow[] = [];
  let webhooks: HermesWebhookRow[] = [];

  if (gate) {
    const [
      apiSkills,
      apiTools,
      apiMcp,
      apiCron,
      apiChannels,
      apiSessions,
      apiPairing,
      apiHooks,
      apiProjects,
    ] = await Promise.all([
      hermesDashboardGet(gate, "/api/skills"),
      hermesDashboardGet(gate, "/api/tools/toolsets"),
      hermesDashboardGet(gate, "/api/mcp/servers"),
      hermesDashboardGet(gate, "/api/cron/jobs"),
      hermesDashboardGet(gate, "/api/messaging/platforms"),
      hermesDashboardGet(gate, "/api/sessions?limit=20&order=recent"),
      hermesDashboardGet(gate, "/api/pairing"),
      hermesDashboardGet(gate, "/api/webhooks"),
      hermesDashboardGet(gate, "/api/projects"),
    ]);
    const nextSkills = skillsFromApi(apiSkills);
    if (nextSkills.length) skills = nextSkills;
    const nextTools = toolsetsFromApi(apiTools);
    if (nextTools.length) toolsets = nextTools;
    const nextMcp = mcpFromApi(apiMcp);
    if (nextMcp.length) mcp = nextMcp;
    const nextCron = cronFromApi(apiCron);
    if (nextCron.length) cron = nextCron;
    const nextChannels = channelsFromApi(apiChannels);
    if (nextChannels.length) channels = nextChannels;
    const nextProjects = projectsFromApi(apiProjects);
    if (nextProjects.length) projects = nextProjects;
    sessions = sessionsFromApi(apiSessions);
    pairing = pairingList(asRec(apiPairing).pending);
    pairingApproved = pairingList(asRec(apiPairing).approved);
    webhooks = webhooksFromApi(apiHooks);
  }

  return {
    ok: true,
    writable,
    owner,
    local,
    skills,
    toolsets,
    mcp,
    cron,
    channels,
    sessions,
    pairing,
    pairingApproved,
    webhooks,
    projects,
  };
}

export async function mutateHermesLive(
  opts: {
    url: string;
    key: string;
    place?: GatewayPlace;
    signal?: AbortSignal;
    local?: boolean;
  },
  action: string,
  body: {
    name?: string;
    enabled?: boolean;
    jobId?: string;
    prompt?: string;
    schedule?: string;
    path?: string;
    description?: string;
  },
): Promise<boolean> {
  if (action === "toggle-skill" && body.name) {
    return hermesDashboardSend(opts, "/api/skills/toggle", "PUT", {
      name: body.name,
      enabled: Boolean(body.enabled),
    });
  }
  if (action === "toggle-toolset" && body.name) {
    return hermesDashboardSend(
      opts,
      `/api/tools/toolsets/${encodeURIComponent(body.name)}`,
      "PUT",
      { enabled: Boolean(body.enabled) },
    );
  }
  if (action === "toggle-mcp" && body.name) {
    return hermesDashboardSend(
      opts,
      `/api/mcp/servers/${encodeURIComponent(body.name)}/enabled`,
      "PUT",
      { enabled: Boolean(body.enabled) },
    );
  }
  if (action === "cron-pause" && body.jobId) {
    return hermesDashboardSend(
      opts,
      `/api/cron/jobs/${encodeURIComponent(body.jobId)}/pause`,
      "POST",
    );
  }
  if (action === "cron-resume" && body.jobId) {
    return hermesDashboardSend(
      opts,
      `/api/cron/jobs/${encodeURIComponent(body.jobId)}/resume`,
      "POST",
    );
  }
  if (action === "cron-create" && body.name && body.prompt && body.schedule) {
    return hermesDashboardSend(opts, "/api/cron/jobs", "POST", {
      name: body.name,
      prompt: body.prompt,
      schedule: body.schedule,
      deliver: "local",
    });
  }
  if (action === "project-create" && body.name) {
    const created = await hermesDashboardSend(opts, "/api/projects", "POST", {
      name: body.name,
      description: body.description || undefined,
      primary_path: body.path || undefined,
      folders: body.path ? [body.path] : [],
    });
    if (created) return true;
    if (opts.local) {
      return createProjectLocally({
        name: body.name,
        path: body.path,
        description: body.description,
      });
    }
  }
  return false;
}

async function createProjectLocally(body: {
  name: string;
  path?: string;
  description?: string;
}): Promise<boolean> {
  const { execFile } = await import("node:child_process");
  const { access } = await import("node:fs/promises");
  const { join } = await import("node:path");
  const { promisify } = await import("node:util");
  const executable = join(
    getHermesHomeDir(),
    "hermes-agent",
    "venv",
    "bin",
    "hermes",
  );
  try {
    await access(executable);
    const args = ["project", "create", body.name];
    if (body.path) args.push(body.path, "--primary", body.path);
    if (body.description) args.push("--description", body.description);
    await promisify(execFile)(executable, args, { timeout: 12_000 });
    return true;
  } catch {
    return false;
  }
}
