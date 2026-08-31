import {
  useEffect,
  useRef,
  useState,
  type Dispatch,
  type SetStateAction,
} from "react";
import {
  listHermesLive,
  mutateHermes,
  readHermesMcpCatalog,
  readHermesMcpOAuth,
  readHermesMcpUsage,
  startHermesMcpOAuth,
  testHermesMcpServer,
  waitForHermesAction,
} from "./hermes-live";
import type {
  HermesLive,
  HermesMcpCatalogRow,
  HermesMcpOAuthFlow,
  HermesMcpRow,
} from "./hermes-live-types";
import { HERMES_CURRENT_STABLE } from "./gateway-contracts";
import { localizeError } from "./i18n";
import {
  mcpProbeCacheKey,
  mcpServerUsageCount,
  type McpProbeState,
} from "./mcp-command-center";
import { useHermes } from "./store";
import { useLocale, useT } from "./use-i18n";

const MCP_HEALTH_TTL_MS = 5 * 60_000;
const mcpProbeCache = new Map<
  string,
  { checkedAt: number; state: McpProbeState }
>();
const mcpUsageCache = new Map<
  string,
  { checkedAt: number; calls: Record<string, number> }
>();

export function useMcpCommandCenter(input: {
  writable: boolean;
  rows: HermesMcpRow[];
  setData: (data: HermesLive) => void;
}) {
  const { writable, rows, setData } = input;
  const t = useT();
  const locale = useLocale();
  const hermesVersion = useHermes(
    (state) => state.gatewayMeta?.manifest?.version,
  );
  const profile = useHermes((state) => state.profile);
  const gatewayUrl = useHermes((state) => state.gatewayUrl);
  const pantheon = hermesVersion === HERMES_CURRENT_STABLE;
  const [busyName, setBusyName] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<string | null>(null);
  const [catalogOpen, setCatalogOpen] = useState(false);
  const [catalogLoading, setCatalogLoading] = useState(false);
  const [catalogLoaded, setCatalogLoaded] = useState(false);
  const [catalogError, setCatalogError] = useState<string | null>(null);
  const [catalogEntries, setCatalogEntries] = useState<HermesMcpCatalogRow[]>(
    [],
  );
  const [catalogDiagnostics, setCatalogDiagnostics] = useState<
    Array<{ name: string; kind: string; message: string }>
  >([]);
  const [probeStates, setProbeStates] = useState<Record<string, McpProbeState>>(
    {},
  );
  const [usageCalls, setUsageCalls] = useState<Record<string, number> | null>(
    null,
  );
  const [oauthFlow, setOauthFlow] = useState<HermesMcpOAuthFlow | null>(null);
  const [oauthPending, setOauthPending] = useState(false);
  const oauthPollFailures = useRef(0);
  const rowsSignature = rows
    .map((row) => `${row.name}:${row.enabled ? "1" : "0"}`)
    .join("|");

  useEffect(() => {
    if (!pantheon || !writable || !rowsSignature) return;
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      void (async () => {
        async function loadUsage() {
          const usageKey = JSON.stringify([gatewayUrl, profile]);
          const cachedUsage = mcpUsageCache.get(usageKey);
          if (
            cachedUsage &&
            Date.now() - cachedUsage.checkedAt < MCP_HEALTH_TTL_MS
          ) {
            setUsageCalls(cachedUsage.calls);
            return;
          }
          const usage = await readHermesMcpUsage({ signal: controller.signal });
          if (!controller.signal.aborted && usage.ok) {
            mcpUsageCache.set(usageKey, {
              checkedAt: Date.now(),
              calls: usage.calls,
            });
            setUsageCalls(usage.calls);
          }
        }

        const queue = rows.filter((row) => row.enabled);
        let cursor = 0;
        async function worker() {
          while (!controller.signal.aborted) {
            const row = queue[cursor++];
            if (!row) return;
            const key = mcpProbeCacheKey({
              gatewayUrl,
              profile,
              serverName: row.name,
            });
            const cached = mcpProbeCache.get(key);
            if (cached && Date.now() - cached.checkedAt < MCP_HEALTH_TTL_MS) {
              setProbeStates((current) => ({
                ...current,
                [row.name]: cached.state,
              }));
              continue;
            }
            setProbeStates((current) => ({
              ...current,
              [row.name]: { state: "checking" },
            }));
            const result = await testHermesMcpServer({
              name: row.name,
              signal: controller.signal,
            });
            if (controller.signal.aborted) return;
            cacheProbe(gatewayUrl, profile, row.name, result, setProbeStates);
          }
        }
        await Promise.all([loadUsage(), worker(), worker()]);
      })();
    }, 250);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [gatewayUrl, pantheon, profile, rows, rowsSignature, writable]);

  useEffect(() => {
    if (
      !oauthFlow ||
      oauthFlow.status === "approved" ||
      oauthFlow.status === "error"
    )
      return;
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      void readHermesMcpOAuth({
        flowId: oauthFlow.flowId,
        signal: controller.signal,
      }).then((result) => {
        if (controller.signal.aborted) return;
        if (!result.ok) {
          oauthPollFailures.current += 1;
          if (oauthPollFailures.current >= 3) {
            setOauthFlow((current) =>
              current
                ? {
                    ...current,
                    status: "error",
                    error: localizeError(locale, result.error),
                  }
                : null,
            );
          }
          return;
        }
        oauthPollFailures.current = 0;
        setOauthFlow(result.flow);
        if (result.flow.status !== "approved") return;
        void listHermesLive({ signal: controller.signal }).then((fresh) => {
          if (!controller.signal.aborted && fresh.ok) setData(fresh);
        });
        void testHermesMcpServer({
          name: result.flow.serverName,
          signal: controller.signal,
        }).then((probeResult) => {
          if (controller.signal.aborted) return;
          cacheProbe(
            gatewayUrl,
            profile,
            result.flow.serverName,
            probeResult,
            setProbeStates,
          );
        });
      });
    }, 1_200);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [gatewayUrl, locale, oauthFlow, profile, setData]);

  async function refresh(): Promise<boolean> {
    const fresh = await listHermesLive();
    if (fresh.ok) {
      setData(fresh);
      return true;
    }
    setFeedback(localizeError(locale, fresh.error));
    return false;
  }

  async function testServer(name: string) {
    if (busyName) return;
    setBusyName(name);
    setFeedback(null);
    setProbeStates((current) => ({
      ...current,
      [name]: { state: "checking" },
    }));
    const result = await testHermesMcpServer({ name });
    cacheProbe(gatewayUrl, profile, name, result, setProbeStates);
    setBusyName(null);
    setFeedback(
      result.ok
        ? t("addons.testOk")
        : localizeError(
            locale,
            result.error || "Hermes couldn’t save the change.",
          ),
    );
  }

  async function openCatalog() {
    setCatalogOpen(true);
    if (catalogLoaded || catalogLoading) return;
    setCatalogLoading(true);
    setCatalogError(null);
    const result = await readHermesMcpCatalog();
    setCatalogLoading(false);
    if (!result.ok) {
      setCatalogError(localizeError(locale, result.error));
      return;
    }
    setCatalogLoaded(true);
    setCatalogEntries(result.entries);
    setCatalogDiagnostics(result.diagnostics);
  }

  async function installCatalogEntry(
    entry: HermesMcpCatalogRow,
    env: Record<string, string>,
  ) {
    if (busyName) return false;
    setBusyName(entry.name);
    setCatalogError(null);
    const result = await mutateHermes({
      action: "mcp-catalog-install",
      name: entry.name,
      env,
    });
    if (!result.ok) {
      setCatalogError(
        localizeError(locale, result.error || t("addons.catalogError")),
      );
      setBusyName(null);
      return false;
    }
    if (result.actionName) {
      const completed = await waitForHermesAction({ name: result.actionName });
      if (!completed.ok) {
        setCatalogError(localizeError(locale, completed.error));
        setBusyName(null);
        return false;
      }
    }
    await refresh();
    const catalog = await readHermesMcpCatalog();
    if (catalog.ok) {
      setCatalogEntries(catalog.entries);
      setCatalogDiagnostics(catalog.diagnostics);
    }
    setBusyName(null);
    setFeedback(t("addons.catalogInstalledFeedback"));
    return true;
  }

  async function authorizeServer(name: string) {
    if (oauthPending) return;
    setOauthPending(true);
    setFeedback(null);
    const result = await startHermesMcpOAuth({ name });
    setOauthPending(false);
    if (!result.ok) {
      setFeedback(localizeError(locale, result.error));
      return;
    }
    oauthPollFailures.current = 0;
    setOauthFlow(result.flow);
    if (result.flow.status === "approved") {
      await refresh();
      await testServer(result.flow.serverName);
    }
  }

  async function cancelOAuth() {
    if (!oauthFlow || oauthPending) return;
    setOauthPending(true);
    const result = await mutateHermes({
      action: "mcp-oauth-cancel",
      flowId: oauthFlow.flowId,
    });
    setOauthPending(false);
    if (result.ok) setOauthFlow(null);
    else setFeedback(localizeError(locale, result.error));
  }

  function mcpMeta(name: string, auth?: string) {
    const state = probeStates[name];
    if (state?.state === "checking") return t("addons.healthChecking");
    if (state?.state === "error") {
      return auth === "oauth" &&
        /auth|oauth|authori[sz]|credential|token/i.test(state.error)
        ? t("addons.healthNeedsAuth")
        : t("addons.healthUnavailable");
    }
    if (state?.state === "ready") {
      const parts = [
        t("addons.healthTools", { count: state.probe.tools.length }),
      ];
      if (state.probe.schemaTokens !== undefined) {
        parts.push(
          t("addons.healthTokens", { count: state.probe.schemaTokens }),
        );
      }
      if (usageCalls) {
        parts.push(
          t("addons.healthUses", {
            count: mcpServerUsageCount(name, usageCalls),
          }),
        );
      }
      if (state.probe.prompts || state.probe.resources) {
        parts.push(
          t("addons.healthCapabilities", {
            prompts: state.probe.prompts,
            resources: state.probe.resources,
          }),
        );
      }
      return parts.join(" · ");
    }
    return auth && auth !== "none" ? auth.toUpperCase() : undefined;
  }

  return {
    pantheon,
    busyName,
    setBusyName,
    feedback,
    setFeedback,
    refresh,
    testServer,
    mcpMeta,
    catalog: {
      open: catalogOpen,
      entries: catalogEntries,
      diagnostics: catalogDiagnostics,
      loading: catalogLoading,
      error: catalogError,
      openCatalog,
      setOpen: setCatalogOpen,
      install: installCatalogEntry,
    },
    oauth: {
      flow: oauthFlow,
      pending: oauthPending,
      authorize: authorizeServer,
      cancel: cancelOAuth,
      close: () => setOauthFlow(null),
    },
  };
}

function cacheProbe(
  gatewayUrl: string,
  profile: string,
  name: string,
  result: Awaited<ReturnType<typeof testHermesMcpServer>>,
  setProbeStates: Dispatch<SetStateAction<Record<string, McpProbeState>>>,
) {
  const state: McpProbeState = result.ok
    ? { state: "ready", probe: result.probe }
    : { state: "error", error: result.error };
  mcpProbeCache.set(
    mcpProbeCacheKey({ gatewayUrl, profile, serverName: name }),
    { checkedAt: Date.now(), state },
  );
  setProbeStates((current) => ({ ...current, [name]: state }));
}
