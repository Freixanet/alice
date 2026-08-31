import type {
  HermesActionStatusResult,
  HermesDiagnosticsResult,
  HermesLiveResult,
  HermesMutationResult,
  HermesMcpCatalogResult,
  HermesMcpOAuthResult,
  HermesMcpProbeResult,
  HermesMcpUsageResult,
  HermesProfileSoulResult,
  HermesProfilesResult,
  HermesSessionMessagesResult,
  HermesSkillContentResult,
  HermesSkillHubSearchResult,
  HermesSystemToolsResult,
  HermesToolsetDetailsResult,
} from "./hermes-live-types";
import { hermesMutationSchema, type HermesMutation } from "./hermes-operations";
import {
  resolveHermesTransport,
  type HermesDirectTransportContext,
  type HermesTransportScope,
} from "./hermes-transport";

export type * from "./hermes-live-types";

type HermesResult = { ok: boolean };
type HermesFailure = { ok: false; error: string };

async function runHermesOperation<TResult extends HermesResult>(opts: {
  signal?: AbortSignal;
  scope: HermesTransportScope;
  proxy: Readonly<Record<string, unknown>>;
  direct: (context: HermesDirectTransportContext) => Promise<TResult>;
  decodeProxy: (value: unknown) => TResult;
}): Promise<TResult | HermesFailure> {
  const resolved = await resolveHermesTransport(
    opts.signal ? { signal: opts.signal } : undefined,
  );
  if (!resolved.ok) return resolved;
  return resolved.transport.execute({
    scope: opts.scope,
    proxy: opts.proxy,
    direct: opts.direct,
    decodeProxy: opts.decodeProxy,
  });
}

function decodeHermesResult<TResult extends HermesResult>(
  value: unknown,
  fallback: string,
): TResult | HermesFailure {
  const record = asRecord(value);
  if (record?.ok === true) return value as TResult;
  return {
    ok: false,
    error:
      typeof record?.error === "string" && record.error.trim()
        ? record.error
        : fallback,
  };
}

export async function listHermesLive(opts?: {
  signal?: AbortSignal;
}): Promise<HermesLiveResult> {
  try {
    return await runHermesOperation({
      ...(opts?.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "live" },
      direct: async (context) => {
        const { listHermesLiveDirect } = await import("./hermes-direct");
        return listHermesLiveDirect(context);
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesLiveResult>(
          value,
          "Couldn’t read Hermes status.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read Hermes status." };
  }
}

export async function mutateHermes(
  opts: HermesMutation,
): Promise<HermesMutationResult> {
  try {
    const parsed = hermesMutationSchema.safeParse(opts);
    if (!parsed.success) {
      return { ok: false, error: "Hermes rejected invalid input." };
    }
    const mutation = parsed.data;
    return await runHermesOperation({
      scope: "profile",
      proxy: { action: "mutate", mutation },
      direct: async (context) => {
        const { mutateHermesDirect } = await import("./hermes-direct");
        return mutateHermesDirect({ ...context, ...mutation });
      },
      decodeProxy: (value) => decodeMutationResult(value, mutation),
    });
  } catch {
    return { ok: false, error: "Hermes couldn’t save the change." };
  }
}

export async function readHermesToolsetDetails(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesToolsetDetailsResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "toolset-details", name: opts.name },
      direct: async (context) => {
        const { readHermesToolsetDetailsDirect } =
          await import("./hermes-direct");
        return readHermesToolsetDetailsDirect({ ...context, name: opts.name });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesToolsetDetailsResult>(
          value,
          "Couldn’t read this Hermes toolset.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes toolset." };
  }
}

export async function readHermesSystemTools(opts?: {
  signal?: AbortSignal;
}): Promise<HermesSystemToolsResult> {
  try {
    return await runHermesOperation({
      ...(opts?.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "system-tools" },
      direct: async (context) => {
        const { readHermesSystemToolsDirect } = await import("./hermes-direct");
        return readHermesSystemToolsDirect(context);
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesSystemToolsResult>(
          value,
          "Couldn’t read Hermes system tools.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read Hermes system tools." };
  }
}

export async function readHermesMcpCatalog(opts?: {
  signal?: AbortSignal;
}): Promise<HermesMcpCatalogResult> {
  try {
    return await runHermesOperation({
      ...(opts?.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "mcp-catalog" },
      direct: async (context) => {
        const { readHermesMcpCatalogDirect } = await import("./hermes-direct");
        return readHermesMcpCatalogDirect(context);
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesMcpCatalogResult>(
          value,
          "Couldn’t read the MCP catalog.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read the MCP catalog." };
  }
}

export async function testHermesMcpServer(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesMcpProbeResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "mcp-probe", name: opts.name },
      direct: async (context) => {
        const { testHermesMcpServerDirect } = await import("./hermes-direct");
        return testHermesMcpServerDirect({ ...context, name: opts.name });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesMcpProbeResult>(
          value,
          "Couldn’t test this MCP server.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t test this MCP server." };
  }
}

export async function startHermesMcpOAuth(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesMcpOAuthResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "mcp-oauth-start", name: opts.name },
      direct: async (context) => {
        const { startHermesMcpOAuthDirect } = await import("./hermes-direct");
        return startHermesMcpOAuthDirect({ ...context, name: opts.name });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesMcpOAuthResult>(
          value,
          "Couldn’t start MCP authorization.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t start MCP authorization." };
  }
}

export async function readHermesMcpOAuth(opts: {
  flowId: string;
  signal?: AbortSignal;
}): Promise<HermesMcpOAuthResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "mcp-oauth-status", flowId: opts.flowId },
      direct: async (context) => {
        const { readHermesMcpOAuthDirect } = await import("./hermes-direct");
        return readHermesMcpOAuthDirect({
          ...context,
          flowId: opts.flowId,
        });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesMcpOAuthResult>(
          value,
          "Couldn’t read MCP authorization.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read MCP authorization." };
  }
}

export async function readHermesMcpUsage(opts?: {
  signal?: AbortSignal;
}): Promise<HermesMcpUsageResult> {
  try {
    return await runHermesOperation({
      ...(opts?.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "mcp-usage" },
      direct: async (context) => {
        const { readHermesMcpUsageDirect } = await import("./hermes-direct");
        return readHermesMcpUsageDirect(context);
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesMcpUsageResult>(
          value,
          "Couldn’t read MCP usage.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read MCP usage." };
  }
}

export async function readHermesProfiles(opts?: {
  signal?: AbortSignal;
}): Promise<HermesProfilesResult> {
  try {
    return await runHermesOperation({
      ...(opts?.signal ? { signal: opts.signal } : {}),
      scope: "global",
      proxy: { action: "profiles" },
      direct: async (context) => {
        const { readHermesProfilesDirect } = await import("./hermes-direct");
        return readHermesProfilesDirect(context);
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesProfilesResult>(
          value,
          "Couldn’t read Hermes profiles.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read Hermes profiles." };
  }
}

export async function readHermesProfileSoul(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesProfileSoulResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "global",
      proxy: { action: "profile-soul", name: opts.name },
      direct: async (context) => {
        const { readHermesProfileSoulDirect } = await import("./hermes-direct");
        return readHermesProfileSoulDirect({ ...context, name: opts.name });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesProfileSoulResult>(
          value,
          "Couldn’t read this profile’s SOUL.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read this profile’s SOUL." };
  }
}

export async function readHermesSkillContent(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesSkillContentResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "skill-content", name: opts.name },
      direct: async (context) => {
        const { readHermesSkillContentDirect } =
          await import("./hermes-direct");
        return readHermesSkillContentDirect({ ...context, name: opts.name });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesSkillContentResult>(
          value,
          "Couldn’t read this Hermes skill.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes skill." };
  }
}

export async function searchHermesSkillsHub(opts: {
  query: string;
  signal?: AbortSignal;
}): Promise<HermesSkillHubSearchResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "skills-search", query: opts.query },
      direct: async (context) => {
        const { searchHermesSkillsHubDirect } = await import("./hermes-direct");
        return searchHermesSkillsHubDirect({ ...context, query: opts.query });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesSkillHubSearchResult>(
          value,
          "Couldn’t search the Skills Hub.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t search the Skills Hub." };
  }
}

export async function readHermesActionStatus(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesActionStatusResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "action-status", name: opts.name },
      direct: async (context) => {
        const { readHermesActionStatusDirect } =
          await import("./hermes-direct");
        return readHermesActionStatusDirect({ ...context, name: opts.name });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesActionStatusResult>(
          value,
          "Couldn’t read the Hermes action.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read the Hermes action." };
  }
}

export async function waitForHermesAction(opts: {
  name: string;
  signal?: AbortSignal;
  pollMs?: number;
  timeoutMs?: number;
}): Promise<{ ok: true; lines: string[] } | { ok: false; error: string }> {
  const started = Date.now();
  const pollMs = Math.max(250, opts.pollMs ?? 1_200);
  const timeoutMs = Math.max(pollMs, opts.timeoutMs ?? 120_000);
  let lines: string[] = [];
  while (Date.now() - started < timeoutMs) {
    if (opts.signal?.aborted) {
      return { ok: false, error: "The Hermes skill action was cancelled." };
    }
    const result = await readHermesActionStatus({
      name: opts.name,
      ...(opts.signal ? { signal: opts.signal } : {}),
    });
    if (!result.ok) return result;
    lines = result.action.lines;
    if (!result.action.running) {
      return result.action.exitCode === 0
        ? { ok: true, lines }
        : {
            ok: false,
            error:
              lines.slice(-3).join("\n").trim() ||
              "Hermes couldn’t finish the skill action.",
          };
    }
    await new Promise((resolve) => window.setTimeout(resolve, pollMs));
  }
  return {
    ok: false,
    error: "Hermes is still working on this skill. Try refreshing shortly.",
  };
}

export async function readHermesDiagnostics(opts?: {
  signal?: AbortSignal;
}): Promise<HermesDiagnosticsResult> {
  try {
    return await runHermesOperation({
      ...(opts?.signal ? { signal: opts.signal } : {}),
      scope: "global",
      proxy: { action: "diagnostics" },
      direct: async (context) => {
        const { readHermesDiagnosticsDirect } = await import("./hermes-direct");
        return readHermesDiagnosticsDirect(context);
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesDiagnosticsResult>(
          value,
          "Couldn’t read Hermes diagnostics.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read Hermes diagnostics." };
  }
}

export async function readHermesSessionMessages(opts: {
  sessionId: string;
  signal?: AbortSignal;
}): Promise<HermesSessionMessagesResult> {
  try {
    return await runHermesOperation({
      ...(opts.signal ? { signal: opts.signal } : {}),
      scope: "profile",
      proxy: { action: "session-messages", sessionId: opts.sessionId },
      direct: async (context) => {
        const { readHermesSessionMessagesDirect } =
          await import("./hermes-direct");
        return readHermesSessionMessagesDirect({
          ...context,
          sessionId: opts.sessionId,
        });
      },
      decodeProxy: (value) =>
        decodeHermesResult<HermesSessionMessagesResult>(
          value,
          "Couldn’t read this Hermes session.",
        ),
    });
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes session." };
  }
}

function decodeMutationResult(
  value: unknown,
  mutation: HermesMutation,
): HermesMutationResult {
  const data = asRecord(value);
  if (data?.ok !== true) {
    return {
      ok: false,
      error:
        typeof data?.error === "string"
          ? data.error
          : "Hermes couldn’t save the change.",
    };
  }
  if (mutation.action === "webhook-create") {
    const secret = typeof data.secret === "string" ? data.secret : "";
    const url = typeof data.url === "string" ? data.url : "";
    return secret && /^https?:\/\//i.test(url)
      ? { ok: true, secret, url }
      : { ok: false, error: "Hermes didn’t return the webhook secret." };
  }
  if (mutation.action === "channel-test") {
    const test = asRecord(data.channelTest);
    if (
      !test ||
      typeof test.ok !== "boolean" ||
      typeof test.message !== "string"
    ) {
      return {
        ok: false,
        error: "Hermes didn’t return a channel test result.",
      };
    }
    return {
      ok: true,
      channelTest: {
        ok: test.ok,
        message: test.message.slice(0, 2_000),
        ...(typeof test.state === "string"
          ? { state: test.state.slice(0, 128) }
          : {}),
      },
    };
  }
  if (
    mutation.action === "skill-install" ||
    mutation.action === "skill-uninstall" ||
    mutation.action === "skills-update"
  ) {
    const actionName =
      typeof data.actionName === "string" ? data.actionName.trim() : "";
    return actionName
      ? { ok: true, actionName }
      : { ok: false, error: "Hermes didn’t start the skill action." };
  }
  if (mutation.action === "mcp-catalog-install") {
    const actionName =
      typeof data.actionName === "string" ? data.actionName.trim() : "";
    return actionName ? { ok: true, actionName } : { ok: true };
  }
  return { ok: true };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
