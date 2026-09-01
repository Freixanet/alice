import type {
  HermesCapability,
  HermesCapabilityManifest,
} from "./gateway-contracts";

/**
 * Discover management features a Hermes serves but does not advertise.
 *
 * `/v1/capabilities` describes the *agent* API — chat, runs, sessions, models.
 * Profiles, analytics, cron, MCP and webhooks live on a separate *management*
 * surface (`/api/*`). Nothing requires a build to describe one in the other, so
 * gating those pages on the agent manifest hides features the connected Hermes
 * actually serves. That is topology-independent: it happens the same way behind
 * Tailscale Serve, a reverse proxy, a cloud host, or on the same machine.
 *
 * So when the manifest is silent about one of these, ask the endpoint itself.
 * Only a 2xx counts as support: a 404 means the build lacks it, and a redirect
 * means a login wall sits in front of it — neither is a working surface.
 */
export const MANAGEMENT_PROBES = [
  { capability: "profiles", path: "/api/profiles" },
  { capability: "insights", path: "/api/analytics/usage" },
  { capability: "cron", path: "/api/cron/jobs" },
  { capability: "mcp", path: "/api/mcp/servers" },
  { capability: "webhooks", path: "/api/webhooks" },
  { capability: "projects", path: "/api/projects" },
] as const satisfies ReadonlyArray<{
  capability: HermesCapability;
  path: string;
}>;

/** Probes run a few at a time so a slow Hermes cannot stall the connection. */
const CONCURRENCY = 2;

export type ManagementProbeFetch = (
  path: string,
) => Promise<{ ok: boolean; status: number } | null>;

/**
 * Returns the capabilities that answered, limited to those `missing` asks for.
 * Never throws: a Hermes that refuses these paths simply reports nothing, and
 * the caller keeps the manifest it already had.
 */
export async function discoverManagementCapabilities(
  missing: ReadonlySet<HermesCapability>,
  probe: ManagementProbeFetch,
): Promise<HermesCapability[]> {
  const pending = MANAGEMENT_PROBES.filter((entry) =>
    missing.has(entry.capability),
  );
  if (pending.length === 0) return [];

  const found: HermesCapability[] = [];
  let cursor = 0;
  async function worker() {
    while (cursor < pending.length) {
      const entry = pending[cursor++];
      if (!entry) return;
      try {
        const result = await probe(entry.path);
        if (result?.ok) found.push(entry.capability);
      } catch {
        // An unreachable management path just means "not supported here".
      }
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(CONCURRENCY, pending.length) }, worker),
  );
  // Keep the declared order so the result is stable regardless of timing.
  return MANAGEMENT_PROBES.filter((entry) =>
    found.includes(entry.capability),
  ).map((entry) => entry.capability);
}

/** Capabilities from `MANAGEMENT_PROBES` that a manifest has not claimed. */
export function missingManagementCapabilities(
  advertised: Partial<Record<HermesCapability, boolean>>,
): Set<HermesCapability> {
  return new Set(
    MANAGEMENT_PROBES.map((entry) => entry.capability).filter(
      (capability) => advertised[capability] !== true,
    ),
  );
}

/**
 * Fold management surfaces the manifest never claimed into it, so a Hermes that
 * serves `/api/profiles` gets the Agents page even when `/v1/capabilities` only
 * describes the chat surface. Returns the manifest untouched when there is
 * nothing to add, and never fails the connection.
 *
 * Discovered entries are tagged in `advertised` so the origin of a capability
 * stays visible when debugging a connection.
 */
export async function withDiscoveredManagement(
  manifest: HermesCapabilityManifest | undefined,
  probe: ManagementProbeFetch,
): Promise<HermesCapabilityManifest | undefined> {
  if (!manifest) return manifest;
  try {
    const missing = missingManagementCapabilities(manifest.capabilities);
    if (missing.size === 0) return manifest;
    const found = await discoverManagementCapabilities(missing, probe);
    if (found.length === 0) return manifest;
    return {
      ...manifest,
      capabilities: {
        ...manifest.capabilities,
        ...Object.fromEntries(found.map((name) => [name, true])),
      },
      advertised: [...manifest.advertised, ...found.map((n) => `${n}:probed`)],
    };
  } catch {
    return manifest;
  }
}
