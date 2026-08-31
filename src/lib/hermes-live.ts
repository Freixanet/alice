import { authHeaders } from "./auth/client";
import type {
  HermesActionStatusResult,
  HermesDiagnosticsResult,
  HermesLiveResult,
  HermesMutationResult,
  HermesProfileSoulResult,
  HermesProfilesResult,
  HermesSessionMessagesResult,
  HermesSkillContentResult,
  HermesSkillHubSearchResult,
  HermesSystemToolsResult,
  HermesToolsetDetailsResult,
} from "./hermes-live-types";
import { hermesMutationSchema, type HermesMutation } from "./hermes-operations";
import { advertisesHermesCapability } from "./gateway-contracts";

export type * from "./hermes-live-types";

export async function listHermesLive(opts?: {
  signal?: AbortSignal;
}): Promise<HermesLiveResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const place = state.gatewayPlace;
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (place === "device") {
      const { getDeviceSessionKey, listHermesLiveDirect } =
        await import("./hermes-direct");
      const url = state.gatewayUrl;
      const key = getDeviceSessionKey();
      if (!url || !key)
        return { ok: false, error: "Connect your Hermes on this computer." };
      return listHermesLiveDirect({
        url,
        key,
        signal: opts?.signal,
        profile,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "live", profile }),
      signal: opts?.signal,
    });
    const data = (await res.json()) as HermesLiveResult;
    if (data && data.ok) return data;
    const message =
      data &&
      "error" in data &&
      typeof data.error === "string" &&
      data.error.trim()
        ? data.error
        : "Couldn’t read Hermes status.";
    return { ok: false, error: message };
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
    opts = parsed.data;
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const place = state.gatewayPlace;
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (place === "device") {
      const { getDeviceSessionKey, mutateHermesDirect } =
        await import("./hermes-direct");
      const url = state.gatewayUrl;
      const key = getDeviceSessionKey();
      if (!url || !key)
        return { ok: false, error: "Connect your Hermes on this computer." };
      return mutateHermesDirect({ url, key, profile, ...opts });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "mutate", profile, mutation: opts }),
    });
    const data = (await res.json()) as Record<string, unknown>;
    if (!data.ok) {
      return {
        ok: false,
        error:
          typeof data.error === "string"
            ? data.error
            : "Hermes couldn’t save the change.",
      };
    }
    if (opts.action === "webhook-create") {
      const secret = typeof data.secret === "string" ? data.secret : "";
      const url = typeof data.url === "string" ? data.url : "";
      if (!secret || !/^https?:\/\//i.test(url)) {
        return {
          ok: false,
          error: "Hermes didn’t return the webhook secret.",
        };
      }
      return { ok: true, secret, url };
    }
    if (opts.action === "channel-test") {
      const test =
        data.channelTest && typeof data.channelTest === "object"
          ? (data.channelTest as Record<string, unknown>)
          : null;
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
          state:
            typeof test.state === "string"
              ? test.state.slice(0, 128)
              : undefined,
        },
      };
    }
    if (
      opts.action === "skill-install" ||
      opts.action === "skill-uninstall" ||
      opts.action === "skills-update"
    ) {
      const actionName =
        typeof data.actionName === "string" ? data.actionName.trim() : "";
      return actionName
        ? { ok: true, actionName }
        : { ok: false, error: "Hermes didn’t start the skill action." };
    }
    return { ok: true };
  } catch {
    return { ok: false, error: "Hermes couldn’t save the change." };
  }
}

export async function readHermesToolsetDetails(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesToolsetDetailsResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesToolsetDetailsDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesToolsetDetailsDirect({
        url: state.gatewayUrl,
        key,
        name: opts.name,
        profile,
        signal: opts.signal,
      });
    }
    const response = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "toolset-details",
        name: opts.name,
        profile,
      }),
      signal: opts.signal,
      cache: "no-store",
    });
    const data = (await response.json()) as HermesToolsetDetailsResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read this Hermes toolset.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes toolset." };
  }
}

export async function readHermesSystemTools(opts?: {
  signal?: AbortSignal;
}): Promise<HermesSystemToolsResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesSystemToolsDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesSystemToolsDirect({
        url: state.gatewayUrl,
        key,
        profile,
        signal: opts?.signal,
      });
    }
    const response = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "system-tools", profile }),
      signal: opts?.signal,
      cache: "no-store",
    });
    const data = (await response.json()) as HermesSystemToolsResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read Hermes system tools.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes system tools." };
  }
}

export async function readHermesProfiles(opts?: {
  signal?: AbortSignal;
}): Promise<HermesProfilesResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesProfilesDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesProfilesDirect({
        url: state.gatewayUrl,
        key,
        signal: opts?.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "profiles" }),
      signal: opts?.signal,
      cache: "no-store",
    });
    const data = (await res.json()) as HermesProfilesResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read Hermes profiles.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes profiles." };
  }
}

export async function readHermesProfileSoul(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesProfileSoulResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesProfileSoulDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesProfileSoulDirect({
        url: state.gatewayUrl,
        key,
        name: opts.name,
        signal: opts.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "profile-soul", name: opts.name }),
      signal: opts.signal,
      cache: "no-store",
    });
    const data = (await res.json()) as HermesProfileSoulResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read this profile’s SOUL.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read this profile’s SOUL." };
  }
}

export async function readHermesSkillContent(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesSkillContentResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesSkillContentDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesSkillContentDirect({
        url: state.gatewayUrl,
        key,
        name: opts.name,
        profile,
        signal: opts.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "skill-content",
        name: opts.name,
        profile,
      }),
      signal: opts.signal,
      cache: "no-store",
    });
    const data = (await res.json()) as HermesSkillContentResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read this Hermes skill.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes skill." };
  }
}

export async function searchHermesSkillsHub(opts: {
  query: string;
  signal?: AbortSignal;
}): Promise<HermesSkillHubSearchResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, searchHermesSkillsHubDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return searchHermesSkillsHubDirect({
        url: state.gatewayUrl,
        key,
        query: opts.query,
        profile,
        signal: opts.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "skills-search",
        query: opts.query,
        profile,
      }),
      signal: opts.signal,
      cache: "no-store",
    });
    const data = (await res.json()) as HermesSkillHubSearchResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t search the Skills Hub.",
        };
  } catch {
    return { ok: false, error: "Couldn’t search the Skills Hub." };
  }
}

export async function readHermesActionStatus(opts: {
  name: string;
  signal?: AbortSignal;
}): Promise<HermesActionStatusResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesActionStatusDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesActionStatusDirect({
        url: state.gatewayUrl,
        key,
        name: opts.name,
        profile,
        signal: opts.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "action-status",
        name: opts.name,
        profile,
      }),
      signal: opts.signal,
      cache: "no-store",
    });
    const data = (await res.json()) as HermesActionStatusResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read the Hermes action.",
        };
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
      signal: opts.signal,
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
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesDiagnosticsDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesDiagnosticsDirect({
        url: state.gatewayUrl,
        key,
        signal: opts?.signal,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "diagnostics" }),
      signal: opts?.signal,
      cache: "no-store",
    });
    const data = (await res.json()) as HermesDiagnosticsResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read Hermes diagnostics.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read Hermes diagnostics." };
  }
}

export async function readHermesSessionMessages(opts: {
  sessionId: string;
  signal?: AbortSignal;
}): Promise<HermesSessionMessagesResult> {
  try {
    const { useHermes } = await import("./store");
    const state = useHermes.getState();
    const profile = advertisesHermesCapability(
      state.gatewayMeta?.manifest,
      "profiles",
    )
      ? state.profile
      : undefined;
    if (state.gatewayPlace === "device") {
      const { getDeviceSessionKey, readHermesSessionMessagesDirect } =
        await import("./hermes-direct");
      const key = getDeviceSessionKey();
      if (!state.gatewayUrl || !key) {
        return { ok: false, error: "Connect your Hermes on this computer." };
      }
      return readHermesSessionMessagesDirect({
        url: state.gatewayUrl,
        key,
        sessionId: opts.sessionId,
        signal: opts.signal,
        profile,
      });
    }
    const res = await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        action: "session-messages",
        sessionId: opts.sessionId,
        profile,
      }),
      signal: opts.signal,
    });
    const data = (await res.json()) as HermesSessionMessagesResult;
    return data && data.ok
      ? data
      : {
          ok: false,
          error:
            data && "error" in data
              ? data.error
              : "Couldn’t read this Hermes session.",
        };
  } catch {
    return { ok: false, error: "Couldn’t read this Hermes session." };
  }
}
