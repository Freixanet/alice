export type SlashCommand = {
  cmd: string;
  hint: string;
};

export const SLASH_COMMANDS: SlashCommand[] = [
  { cmd: "/new", hint: "Start a new chat" },
  { cmd: "/control", hint: "Manage Hermes from chat" },
  { cmd: "/agents", hint: "Agents" },
  { cmd: "/bot", hint: "Open or create a bot" },
  { cmd: "/routines", hint: "Routines" },
  { cmd: "/routine", hint: "Run, pause or resume a routine" },
  { cmd: "/providers", hint: "Model providers" },
  { cmd: "/provider", hint: "Connect or disconnect a provider" },
  { cmd: "/usage", hint: "Usage and cost" },
  { cmd: "/project", hint: "Use or create a Project" },
  { cmd: "/model", hint: "Switch model" },
  { cmd: "/help", hint: "List commands" },
  { cmd: "/status", hint: "Status of this session" },
  { cmd: "/update", hint: "Update Hermes" },
  { cmd: "/tools", hint: "Available tools" },
  { cmd: "/skills", hint: "Skills" },
  { cmd: "/memory", hint: "Memory" },
  { cmd: "/save", hint: "Save the conversation" },
  { cmd: "/retry", hint: "Retry the last message" },
  { cmd: "/undo", hint: "Remove the last turn" },
  { cmd: "/title", hint: "Set the chat title" },
  { cmd: "/stop", hint: "Stop what’s running" },
  { cmd: "/plan", hint: "Enter plan mode" },
  { cmd: "/personality", hint: "Change the tone" },
  { cmd: "/compress", hint: "Summarize the context" },
  { cmd: "/clear", hint: "Clear and start over" },
  { cmd: "/config", hint: "View configuration" },
  { cmd: "/reasoning", hint: "Reasoning level" },
  { cmd: "/fast", hint: "Faster replies" },
  { cmd: "/focus", hint: "Less noise in the reply" },
  { cmd: "/yolo", hint: "Act without asking" },
  { cmd: "/approvals", hint: "How to ask for permission" },
  { cmd: "/browser", hint: "The browser" },
  { cmd: "/cron", hint: "Scheduled jobs" },
  { cmd: "/projects", hint: "Projects" },
  { cmd: "/learn", hint: "Learn a skill" },
  { cmd: "/resume", hint: "Resume a previous chat" },
  { cmd: "/sessions", hint: "Your sessions" },
  { cmd: "/history", hint: "History of this chat" },
  { cmd: "/context", hint: "How much context is in use" },
  { cmd: "/agents", hint: "Agents running" },
  { cmd: "/background", hint: "Start a background task" },
  { cmd: "/branch", hint: "Branch this chat" },
  { cmd: "/review", hint: "Review recent work" },
  { cmd: "/goal", hint: "Session goal" },
  { cmd: "/steer", hint: "Note mid-reply" },
  { cmd: "/queue", hint: "Queue the next message" },
  { cmd: "/bundles", hint: "Skill bundles" },
  { cmd: "/init", hint: "Prepare the project" },
  { cmd: "/verbose", hint: "More detail from tools" },
  { cmd: "/reset", hint: "Same as /new" },
];

export function slashQuery(draft: string): string | null {
  if (!draft.startsWith("/")) return null;
  if (draft.includes("\n")) return null;
  const space = draft.indexOf(" ");
  if (space !== -1) return null;
  return draft.toLowerCase();
}

export function matchSlash(
  draft: string,
  extra: SlashCommand[] = [],
): SlashCommand[] {
  const q = slashQuery(draft);
  if (q === null) return [];
  const all = [...SLASH_COMMANDS, ...extra];
  const seen = new Set<string>();
  const hits: SlashCommand[] = [];
  for (const item of all) {
    if (seen.has(item.cmd)) continue;
    if (
      q === "/" ||
      item.cmd.startsWith(q) ||
      item.cmd.slice(1).includes(q.slice(1))
    ) {
      seen.add(item.cmd);
      hits.push(item);
    }
    if (hits.length >= 14) break;
  }
  return hits;
}
