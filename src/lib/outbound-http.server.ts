import { lookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import {
  Client,
  buildConnector,
  fetch as undiciFetch,
  type RequestInit as UndiciRequestInit,
  type Response as UndiciResponse,
} from "undici";

const IPV4_BLOCKS = [
  "0.0.0.0/8",
  "10.0.0.0/8",
  "100.64.0.0/10",
  "127.0.0.0/8",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.0.0.0/24",
  "192.0.2.0/24",
  "192.88.99.0/24",
  "192.168.0.0/16",
  "198.18.0.0/15",
  "198.51.100.0/24",
  "203.0.113.0/24",
  "224.0.0.0/4",
  "240.0.0.0/4",
] as const;

const IPV6_BLOCKS = [
  ["::", 128],
  ["::1", 128],
  ["64:ff9b:1::", 48],
  ["100::", 64],
  ["2001:db8::", 32],
  ["2001:10::", 28],
  ["2002::", 16],
  ["fc00::", 7],
  ["fe80::", 10],
  ["fec0::", 10],
  ["ff00::", 8],
] as const;

const BLOCKED_NETWORKS = new BlockList();
for (const cidr of IPV4_BLOCKS) {
  const [address, prefix] = cidr.split("/");
  if (address && prefix) {
    BLOCKED_NETWORKS.addSubnet(address, Number(prefix), "ipv4");
  }
}
for (const [address, prefix] of IPV6_BLOCKS) {
  BLOCKED_NETWORKS.addSubnet(address, prefix, "ipv6");
}

export class UnsafeOutboundUrlError extends Error {
  constructor(readonly reason: "invalid" | "private" | "unreachable") {
    super(`Unsafe outbound URL: ${reason}`);
    this.name = "UnsafeOutboundUrlError";
  }
}

export type PinnedTarget = {
  url: URL;
  address: string;
  family: 4 | 6;
};

type DnsLookup = (
  hostname: string,
  options: { all: true; verbatim: true },
) => Promise<Array<{ address: string; family: number }>>;

export function isBlockedNetworkAddress(value: string): boolean {
  const address = value.toLowerCase().replace(/^\[|\]$/g, "");
  const family = isIP(address);
  if (family === 4) return BLOCKED_NETWORKS.check(address, "ipv4");
  if (family === 6) return BLOCKED_NETWORKS.check(address, "ipv6");
  return true;
}

export function localPrivateNetworkEnabled(): boolean {
  if (process.env.VERCEL || process.env.NODE_ENV === "production") return false;
  const value = process.env.ALICE_LOCAL_HERMES?.trim().toLowerCase();
  return value !== "0" && value !== "false" && value !== "off";
}

function parseHttpUrl(raw: string | URL): URL {
  let url: URL;
  try {
    url = raw instanceof URL ? new URL(raw) : new URL(raw);
  } catch {
    throw new UnsafeOutboundUrlError("invalid");
  }
  if (
    (url.protocol !== "http:" && url.protocol !== "https:") ||
    url.username ||
    url.password
  ) {
    throw new UnsafeOutboundUrlError("invalid");
  }
  return url;
}

export async function resolvePinnedTarget(
  raw: string | URL,
  options: { allowPrivate?: boolean; lookup?: DnsLookup } = {},
): Promise<PinnedTarget> {
  const url = parseHttpUrl(raw);
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  const literalFamily = isIP(hostname);
  if (literalFamily) {
    if (!options.allowPrivate && isBlockedNetworkAddress(hostname)) {
      throw new UnsafeOutboundUrlError("private");
    }
    return {
      url,
      address: hostname,
      family: literalFamily as 4 | 6,
    };
  }

  let records: Array<{ address: string; family: number }>;
  try {
    const resolver: DnsLookup =
      options.lookup ??
      ((host, resolverOptions) => lookup(host, resolverOptions));
    records = await resolver(hostname, {
      all: true,
      verbatim: true,
    });
  } catch {
    throw new UnsafeOutboundUrlError("unreachable");
  }
  if (!Array.isArray(records) || records.length === 0) {
    throw new UnsafeOutboundUrlError("unreachable");
  }
  if (
    !options.allowPrivate &&
    records.some((record) => isBlockedNetworkAddress(record.address))
  ) {
    throw new UnsafeOutboundUrlError("private");
  }
  // Prefer IPv4 on dual-stack hosts. Node's pinned connector does not perform
  // Happy Eyeballs for the address we supply, so choosing IPv6 unconditionally
  // makes otherwise healthy hosts unreachable on IPv4-only networks.
  const selected =
    records.find((record) => record.family === 4) ??
    records.find((record) => record.family === 6);
  if (!selected || (selected.family !== 4 && selected.family !== 6)) {
    throw new UnsafeOutboundUrlError("unreachable");
  }
  return { url, address: selected.address, family: selected.family };
}

export async function assertPublicHttpUrl(raw: string): Promise<string> {
  const target = await resolvePinnedTarget(raw);
  return target.url.toString().replace(/\/$/, "");
}

/**
 * Resolve, validate and pin one outbound request to the checked IP address.
 * Redirects are always surfaced to the caller and never followed implicitly.
 */
export async function pinnedFetch(
  input: string | URL,
  init: RequestInit = {},
): Promise<Response> {
  const allowPrivate = localPrivateNetworkEnabled();
  const target = await resolvePinnedTarget(input, { allowPrivate });
  if (allowPrivate && isBlockedNetworkAddress(target.address)) {
    return fetch(target.url, { ...init, redirect: "manual" });
  }

  const connector = buildConnector({});
  const dispatcher = new Client(target.url.origin, {
    pipelining: 0,
    keepAliveTimeout: 1_000,
    connect(options, callback) {
      connector(
        {
          ...options,
          hostname: target.address,
          servername: isIP(target.url.hostname)
            ? undefined
            : target.url.hostname,
        },
        callback,
      );
    },
  });
  const destroyTimer = setTimeout(() => void dispatcher.destroy(), 190_000);
  destroyTimer.unref();
  try {
    const response = await undiciFetch(target.url, {
      ...(init as unknown as UndiciRequestInit),
      redirect: "manual",
      dispatcher,
    });
    return responseWithDispatcherCleanup(response, dispatcher, destroyTimer);
  } catch (error) {
    clearTimeout(destroyTimer);
    await dispatcher.destroy(error instanceof Error ? error : null);
    throw error;
  }
}

function responseWithDispatcherCleanup(
  response: UndiciResponse,
  dispatcher: Client,
  timer: ReturnType<typeof setTimeout>,
): Response {
  const finish = () => {
    clearTimeout(timer);
    void dispatcher.close();
  };
  if (!response.body) {
    finish();
    return new Response(null, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    });
  }
  const reader = (
    response.body as unknown as ReadableStream<Uint8Array>
  ).getReader();
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const next = await reader.read();
        if (next.done) {
          controller.close();
          finish();
        } else {
          controller.enqueue(next.value);
        }
      } catch (error) {
        controller.error(error);
        clearTimeout(timer);
        void dispatcher.destroy(error instanceof Error ? error : null);
      }
    },
    async cancel(reason) {
      try {
        await reader.cancel(reason);
      } finally {
        clearTimeout(timer);
        await dispatcher.destroy();
      }
    },
  });
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}
