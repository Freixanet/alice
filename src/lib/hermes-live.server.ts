import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { localHermesAvailable } from "./auth/owner.server";
import {
  getHermesHomeDir,
  hermesDashboardGet,
  hermesDashboardSend,
  hermesDashboardSendJson,
} from "./gateway.server";
import type { GatewayPlace } from "./gateway";
import type {
  HermesActionStatusResult,
  HermesChannelRow,
  HermesCronRow,
  HermesDiagnosticsResult,
  HermesLive,
  HermesMutationResult,
  HermesMcpRow,
  HermesPairingRow,
  HermesProjectRow,
  HermesPluginRow,
  HermesProfileSoulResult,
  HermesProfilesResult,
  HermesSessionRow,
  HermesSessionMessagesResult,
  HermesSkillContentResult,
  HermesSkillHubSearchResult,
  HermesSkillRow,
  HermesToolsetRow,
  HermesToolsetDetailsResult,
} from "./hermes-live";
import {
  asList,
  asRec,
  channelTestFromApi,
  channelsFromApi,
  cronDeliveryTargetsFromApi,
  cronFromApi,
  curatorFromApi,
  cronFromUnknown,
  diagnosticsFromApi,
  groupLabel,
  mcpFromApi,
  pairingList,
  prettyName,
  projectsFromApi,
  pluginsFromApi,
  profilesFromApi,
  sessionsFromApi,
  sessionMessagesFromApi,
  skillHubResultsFromApi,
  skillsFromApi,
  str,
  toolsetsFromApi,
  toolsetDetailsFromApi,
  webhookCreationFromApi,
  webhooksFromApi,
} from "./hermes-live-parse";
import {
  hermesProjectCliArgsFor,
  hermesScopedOperationFor,
  type HermesMutation,
} from "./hermes-operations";

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

function profiledPath(path: string, profile?: string): string {
  if (!profile) return path;
  const separator = path.includes("?") ? "&" : "?";
  return `${path}${separator}profile=${encodeURIComponent(profile)}`;
}

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
    const description = (folded[1] ?? "")
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
      gatewayRunning: false,
      envVars: [],
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
      gatewayRunning: false,
      envVars: [],
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
    project_cols={r["name"] for r in con.execute("pragma table_info(projects)").fetchall()}
    board_select="board_slug" if "board_slug" in project_cols else "null as board_slug"
    rows=con.execute(f"select id,slug,name,description,{board_select},primary_path,archived from projects order by created_at asc").fetchall()
except sqlite3.OperationalError:
    print("[]"); raise SystemExit
try:
    active_row=con.execute("select value from project_meta where key='active_id'").fetchone()
    active_id=active_row["value"] if active_row else None
except sqlite3.OperationalError:
    active_id=None
out=[]
for r in rows:
    folders=[]
    try:
        folder_cols={row["name"] for row in con.execute("pragma table_info(project_folders)").fetchall()}
        label_select="label" if "label" in folder_cols else "null as label"
        order_by=" order by added_at asc" if "added_at" in folder_cols else ""
        folders=con.execute(f"select path,{label_select},is_primary from project_folders where project_id=?{order_by}", (r["id"],)).fetchall()
    except sqlite3.OperationalError:
        pass
    primary=r["primary_path"] or next((f["path"] for f in folders if f["is_primary"]), None) or (folders[0]["path"] if folders else None)
    out.append({"id":r["id"],"slug":r["slug"],"name":r["name"],"description":r["description"] or "","board_slug":r["board_slug"],"primary_path":primary,"folders":[{"path":f["path"],"label":f["label"],"is_primary":bool(f["is_primary"])} for f in folders],"active":r["id"]==active_id,"archived":bool(r["archived"])})
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
  profile?: string;
}): Promise<HermesLive> {
  const writable = Boolean(opts?.url && opts.key);
  const owner = Boolean(opts?.owner);
  const local = localHermesAvailable();
  // A profile-scoped request must never fall back to the dashboard process's
  // own files: an empty remote collection is valid and must remain empty.
  const readDisk = owner && local && opts?.local !== false && !opts?.profile;
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
    plugins: [] as HermesPluginRow[],
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
  let plugins = empty.plugins;
  let pluginsSupported = false;
  let mcp = disk.mcp;
  let cron = disk.cron;
  let cronDeliveryTargets: HermesLive["cronDeliveryTargets"] = [];
  let channels = disk.channels;
  let projects = disk.projects;
  let sessions: HermesSessionRow[] = [];
  let pairing: HermesPairingRow[] = [];
  let pairingApproved: HermesPairingRow[] = [];
  let webhooks: HermesLive["webhooks"] = {
    enabled: false,
    subscriptions: [],
  };
  let curator: HermesLive["curator"] = null;

  if (gate) {
    const [
      apiSkills,
      apiTools,
      apiMcp,
      apiPlugins,
      apiCron,
      apiCronDeliveryTargets,
      apiChannels,
      apiSessions,
      apiPairing,
      apiHooks,
      apiProjects,
      apiCurator,
    ] = await Promise.all([
      hermesDashboardGet(gate, profiledPath("/api/skills", opts?.profile)),
      hermesDashboardGet(
        gate,
        profiledPath("/api/tools/toolsets", opts?.profile),
      ),
      hermesDashboardGet(gate, profiledPath("/api/mcp/servers", opts?.profile)),
      hermesDashboardGet(
        gate,
        profiledPath("/api/dashboard/plugins/hub", opts?.profile),
      ),
      hermesDashboardGet(gate, profiledPath("/api/cron/jobs", opts?.profile)),
      hermesDashboardGet(
        gate,
        profiledPath("/api/cron/delivery-targets", opts?.profile),
      ),
      hermesDashboardGet(
        gate,
        profiledPath("/api/messaging/platforms", opts?.profile),
      ),
      hermesDashboardGet(
        gate,
        profiledPath("/api/sessions?limit=20&order=recent", opts?.profile),
      ),
      hermesDashboardGet(gate, profiledPath("/api/pairing", opts?.profile)),
      hermesDashboardGet(gate, profiledPath("/api/webhooks", opts?.profile)),
      hermesDashboardGet(gate, profiledPath("/api/projects", opts?.profile)),
      hermesDashboardGet(gate, profiledPath("/api/curator", opts?.profile)),
    ]);
    const nextSkills = skillsFromApi(apiSkills);
    if (nextSkills.length) skills = nextSkills;
    const nextTools = toolsetsFromApi(apiTools);
    if (nextTools.length) toolsets = nextTools;
    const nextMcp = mcpFromApi(apiMcp);
    if (nextMcp.length) mcp = nextMcp;
    plugins = pluginsFromApi(apiPlugins);
    pluginsSupported = apiPlugins !== null;
    const nextCron = cronFromApi(apiCron);
    if (nextCron.length) cron = nextCron;
    cronDeliveryTargets = cronDeliveryTargetsFromApi(apiCronDeliveryTargets);
    const nextChannels = channelsFromApi(apiChannels);
    if (nextChannels.length) channels = nextChannels;
    const nextProjects = projectsFromApi(apiProjects);
    if (nextProjects.length) projects = nextProjects;
    sessions = sessionsFromApi(apiSessions);
    pairing = pairingList(asRec(apiPairing).pending);
    pairingApproved = pairingList(asRec(apiPairing).approved);
    webhooks = webhooksFromApi(apiHooks);
    curator = curatorFromApi(apiCurator);
  }

  return {
    ok: true,
    writable,
    owner,
    local,
    skills,
    toolsets,
    plugins,
    pluginsSupported,
    mcp,
    cron,
    cronDeliveryTargets,
    channels,
    sessions,
    pairing,
    pairingApproved,
    webhooks,
    projects,
    curator,
  };
}

export async function fetchHermesProfiles(
  opts: Gate,
): Promise<HermesProfilesResult> {
  const [listed, activeRaw] = await Promise.all([
    hermesDashboardGet(opts, "/api/profiles"),
    hermesDashboardGet(opts, "/api/profiles/active"),
  ]);
  const profiles = profilesFromApi(listed);
  if (!profiles.length) {
    return { ok: false, error: "Hermes didn’t return any profiles." };
  }
  const activeRecord = asRec(activeRaw);
  const fallback = profiles[0]?.name ?? "default";
  return {
    ok: true,
    state: {
      active: str(activeRecord.active) || fallback,
      current: str(activeRecord.current) || fallback,
      profiles,
    },
  };
}

export async function fetchHermesProfileSoul(
  opts: Gate,
  name: string,
): Promise<HermesProfileSoulResult> {
  const raw = await hermesDashboardGet(
    opts,
    `/api/profiles/${encodeURIComponent(name)}/soul`,
  );
  if (!raw) return { ok: false, error: "Couldn’t read this profile’s SOUL." };
  const record = asRec(raw);
  return {
    ok: true,
    content: typeof record.content === "string" ? record.content : "",
    exists: record.exists === true,
  };
}

export async function fetchHermesToolsetDetails(
  opts: Gate,
  name: string,
  profile?: string,
): Promise<HermesToolsetDetailsResult> {
  const encoded = encodeURIComponent(name);
  try {
    const [config, models] = await Promise.all([
      hermesDashboardGet(
        opts,
        profiledPath(`/api/tools/toolsets/${encoded}/config`, profile),
      ),
      hermesDashboardGet(
        opts,
        profiledPath(`/api/tools/toolsets/${encoded}/models`, profile),
      ),
    ]);
    if (!config) {
      return {
        ok: false,
        error: "This Hermes can’t configure this toolset here.",
      };
    }
    return { ok: true, details: toolsetDetailsFromApi(name, config, models) };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes toolset." };
  }
}

export async function fetchHermesSkillContent(
  opts: Gate,
  name: string,
  profile?: string,
): Promise<HermesSkillContentResult> {
  const raw = await hermesDashboardGet(
    opts,
    profiledPath(
      `/api/skills/content?name=${encodeURIComponent(name)}`,
      profile,
    ),
  );
  const record = asRec(raw);
  const content = typeof record.content === "string" ? record.content : null;
  return content === null
    ? { ok: false, error: "Couldn’t read this Hermes skill." }
    : { ok: true, name: str(record.name) || name, content };
}

export async function searchHermesSkillsHub(
  opts: Gate,
  query: string,
  profile?: string,
): Promise<HermesSkillHubSearchResult> {
  const raw = await hermesDashboardGet(
    opts,
    profiledPath(
      `/api/skills/hub/search?q=${encodeURIComponent(query)}&source=all&limit=20`,
      profile,
    ),
  );
  return raw
    ? { ok: true, results: skillHubResultsFromApi(raw) }
    : { ok: false, error: "Couldn’t search the Skills Hub." };
}

export async function fetchHermesActionStatus(
  opts: Gate,
  name: string,
  profile?: string,
): Promise<HermesActionStatusResult> {
  const raw = await hermesDashboardGet(
    opts,
    profiledPath(
      `/api/actions/${encodeURIComponent(name)}/status?lines=200`,
      profile,
    ),
  );
  const record = asRec(raw);
  if (typeof record.running !== "boolean") {
    return { ok: false, error: "Couldn’t read the Hermes action." };
  }
  return {
    ok: true,
    action: {
      name: str(record.name) || name,
      running: record.running,
      exitCode: typeof record.exit_code === "number" ? record.exit_code : null,
      lines: Array.isArray(record.lines)
        ? record.lines.map(str).filter(Boolean).slice(-200)
        : [],
    },
  };
}

export async function fetchHermesSessionMessages(
  opts: Gate,
  sessionId: string,
  profile?: string,
): Promise<HermesSessionMessagesResult> {
  const raw = await hermesDashboardGet(
    opts,
    profiledPath(
      `/api/sessions/${encodeURIComponent(sessionId)}/messages?limit=50&order=latest`,
      profile,
    ),
  );
  if (!raw) {
    return { ok: false, error: "Couldn’t read this Hermes session." };
  }
  const record = asRec(raw);
  return {
    ok: true,
    sessionId: str(record.session_id) || sessionId,
    messages: sessionMessagesFromApi(raw),
  };
}

export async function fetchHermesDiagnostics(
  opts: Gate,
): Promise<HermesDiagnosticsResult> {
  const raw = await hermesDashboardGet(opts, "/health/detailed");
  return raw
    ? { ok: true, diagnostics: diagnosticsFromApi(raw) }
    : { ok: false, error: "Couldn’t read Hermes diagnostics." };
}

export async function mutateHermesLive(
  opts: {
    url: string;
    key: string;
    place?: GatewayPlace;
    signal?: AbortSignal;
    local?: boolean;
  },
  mutation: HermesMutation,
  profile?: string,
): Promise<HermesMutationResult> {
  const operation = hermesScopedOperationFor(mutation, profile);
  if (operation) {
    if (
      mutation.action === "skill-install" ||
      mutation.action === "skill-uninstall" ||
      mutation.action === "skills-update"
    ) {
      const raw = await hermesDashboardSendJson(
        opts,
        operation.path,
        operation.method,
        operation.body,
      );
      const actionName = str(asRec(raw).name);
      return actionName
        ? { ok: true, actionName }
        : { ok: false, error: "Hermes didn’t start the skill action." };
    }
    if (mutation.action === "webhook-create") {
      const raw = await hermesDashboardSendJson(
        opts,
        operation.path,
        operation.method,
        operation.body,
      );
      const created = webhookCreationFromApi(raw);
      return created
        ? { ok: true, ...created }
        : { ok: false, error: "Hermes didn’t return the webhook secret." };
    }
    if (mutation.action === "channel-test") {
      const raw = await hermesDashboardSendJson(
        opts,
        operation.path,
        operation.method,
        operation.body,
      );
      const channelTest = channelTestFromApi(raw);
      return channelTest
        ? { ok: true, channelTest }
        : { ok: false, error: "Hermes didn’t return a channel test result." };
    }
    const ok = await hermesDashboardSend(
      opts,
      operation.path,
      operation.method,
      operation.body,
    );
    return ok
      ? { ok: true }
      : { ok: false, error: "Hermes couldn’t save the change." };
  }
  const projectArgs = hermesProjectCliArgsFor(mutation);
  if (projectArgs && opts.local) {
    const ok = await mutateProjectLocally(projectArgs, profile);
    return ok
      ? { ok: true }
      : { ok: false, error: "Hermes couldn’t save the change." };
  }
  return { ok: false, error: "Hermes couldn’t save the change." };
}

async function mutateProjectLocally(
  projectArgs: string[],
  profile?: string,
): Promise<boolean> {
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
    const args = profile ? ["-p", profile, ...projectArgs] : projectArgs;
    await promisify(execFile)(executable, args, { timeout: 12_000 });
    return true;
  } catch {
    return false;
  }
}
