import type { HermesMcpProbe } from "./hermes-live-types";

export type McpProbeState =
  | { state: "checking" }
  | { state: "ready"; probe: HermesMcpProbe }
  | { state: "error"; error: string };

export function mcpUsagePrefix(serverName: string) {
  return `mcp__${serverName.replace(/[^A-Za-z0-9_]/g, "_")}__`;
}

export function mcpServerUsageCount(
  serverName: string,
  calls: Readonly<Record<string, number>>,
) {
  const prefix = mcpUsagePrefix(serverName);
  return Object.entries(calls).reduce(
    (total, [tool, count]) =>
      tool.startsWith(prefix) && Number.isFinite(count) && count > 0
        ? total + count
        : total,
    0,
  );
}

export function mcpProbeCacheKey(input: {
  profile: string;
  gatewayUrl: string;
  serverName: string;
}) {
  return JSON.stringify([input.gatewayUrl, input.profile, input.serverName]);
}
