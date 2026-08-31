import { authHeaders } from "./auth/client";
import { advertisesHermesCapability } from "./gateway-contracts";

export type HermesTransportKind = "direct" | "proxy";

export type HermesTransportScope = "global" | "profile";

export type HermesDirectTransportContext = Readonly<{
  url: string;
  key: string;
  profile?: string;
  signal?: AbortSignal;
}>;

export type HermesTransportOperation<TResult> = Readonly<{
  scope: HermesTransportScope;
  proxy: Readonly<Record<string, unknown>>;
  direct: (context: HermesDirectTransportContext) => Promise<TResult>;
  decodeProxy: (value: unknown) => TResult;
}>;

/**
 * The browser-facing Hermes boundary. The connection key is deliberately kept
 * inside the direct adapter closure and can never be inspected or serialized by
 * callers. Both adapters expose the same operation contract while retaining
 * their separate network trust boundaries.
 */
export interface HermesTransport {
  readonly kind: HermesTransportKind;
  execute<TResult>(
    operation: HermesTransportOperation<TResult>,
  ): Promise<TResult>;
}

export type HermesTransportResolution =
  { ok: true; transport: HermesTransport } | { ok: false; error: string };

type DirectTransportConfig = Readonly<{
  url: string;
  key: string;
  profile?: string;
  signal?: AbortSignal;
}>;

type ProxyTransportConfig = Readonly<{
  profile?: string;
  signal?: AbortSignal;
  fetcher?: typeof fetch;
}>;

export function createDirectHermesTransport(
  config: DirectTransportConfig,
): HermesTransport {
  return {
    kind: "direct",
    async execute<TResult>(
      operation: HermesTransportOperation<TResult>,
    ): Promise<TResult> {
      return operation.direct({
        url: config.url,
        key: config.key,
        ...(operation.scope === "profile" && config.profile
          ? { profile: config.profile }
          : {}),
        ...(config.signal ? { signal: config.signal } : {}),
      });
    },
  };
}

export function createProxyHermesTransport(
  config: ProxyTransportConfig = {},
): HermesTransport {
  const fetcher = config.fetcher ?? fetch;
  return {
    kind: "proxy",
    async execute<TResult>(
      operation: HermesTransportOperation<TResult>,
    ): Promise<TResult> {
      const response = await fetcher("/api/hermes", {
        method: "POST",
        headers: authHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify({
          ...operation.proxy,
          ...(operation.scope === "profile" && config.profile
            ? { profile: config.profile }
            : {}),
        }),
        cache: "no-store",
        ...(config.signal ? { signal: config.signal } : {}),
      });
      return operation.decodeProxy(await response.json());
    },
  };
}

export async function resolveHermesTransport(opts?: {
  signal?: AbortSignal;
}): Promise<HermesTransportResolution> {
  const { useHermes } = await import("./store");
  const state = useHermes.getState();
  const profile = advertisesHermesCapability(
    state.gatewayMeta?.manifest,
    "profiles",
  )
    ? state.profile
    : undefined;

  if (state.gatewayPlace === "device") {
    const { getDeviceSessionKey } = await import("./hermes-secret-client");
    const key = getDeviceSessionKey();
    if (!state.gatewayUrl || !key) {
      return { ok: false, error: "Connect your Hermes on this computer." };
    }
    return {
      ok: true,
      transport: createDirectHermesTransport({
        url: state.gatewayUrl,
        key,
        ...(profile ? { profile } : {}),
        ...(opts?.signal ? { signal: opts.signal } : {}),
      }),
    };
  }

  return {
    ok: true,
    transport: createProxyHermesTransport({
      ...(profile ? { profile } : {}),
      ...(opts?.signal ? { signal: opts.signal } : {}),
    }),
  };
}
