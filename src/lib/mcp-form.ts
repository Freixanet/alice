import type { HermesMutation } from "./hermes-operations";

export type McpTransport = "http" | "stdio";
export type McpAuth = "none" | "oauth" | "header";

export type McpDraft = {
  name: string;
  transport: McpTransport;
  url: string;
  command: string;
  args: string;
  env: string;
  auth: McpAuth;
  bearerToken: string;
};

export type McpDraftResult =
  | { ok: true; mutation: Extract<HermesMutation, { action: "mcp-create" }> }
  | { ok: false; error: "name" | "url" | "command" | "env" };

const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/;

export function mcpMutationFromDraft(draft: McpDraft): McpDraftResult {
  const name = draft.name.trim();
  if (!name) return { ok: false, error: "name" };

  const url = draft.url.trim();
  const command = draft.command.trim();
  if (draft.transport === "http" && !/^https?:\/\//i.test(url)) {
    return { ok: false, error: "url" };
  }
  if (draft.transport === "stdio" && !command) {
    return { ok: false, error: "command" };
  }

  const env: Record<string, string> = {};
  for (const rawLine of draft.env.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;
    const separator = line.indexOf("=");
    const key = separator < 0 ? "" : line.slice(0, separator).trim();
    if (!ENV_NAME.test(key)) return { ok: false, error: "env" };
    env[key] = line.slice(separator + 1);
  }

  return {
    ok: true,
    mutation: {
      action: "mcp-create",
      name,
      ...(draft.transport === "http" ? { url } : { command }),
      args:
        draft.transport === "stdio"
          ? draft.args
              .split("\n")
              .map((value) => value.trim())
              .filter(Boolean)
          : [],
      env,
      auth: draft.transport === "http" ? draft.auth : "none",
      ...(draft.auth === "header" && draft.bearerToken.trim()
        ? { bearerToken: draft.bearerToken.trim() }
        : {}),
    },
  };
}
