import { execFileSync } from "node:child_process";

const CACHE_MS = 10_000;
let cachedHost: { value: string | null; expiresAt: number } | undefined;

function stripDot(host: string): string {
  return host.replace(/\.$/, "").trim();
}

/** MagicDNS name for this Mac on the tailnet, or null if Tailscale is down. */
export function tailnetHost(options?: {
  now?: number;
  read?: () => string | null;
}): string | null {
  const fromEnv = process.env.ALICE_TAILNET_HOST?.trim();
  if (fromEnv) return stripDot(fromEnv);
  const now = options?.now ?? Date.now();
  if (cachedHost && now < cachedHost.expiresAt) return cachedHost.value;
  const value = (options?.read ?? readSystemTailnetHost)();
  cachedHost = { value, expiresAt: now + CACHE_MS };
  return value;
}

function readSystemTailnetHost(): string | null {
  try {
    const raw = execFileSync("tailscale", ["status", "--json"], {
      encoding: "utf8",
      timeout: 2500,
    });
    const data = JSON.parse(raw) as { Self?: { DNSName?: string } };
    const host = data.Self?.DNSName ? stripDot(data.Self.DNSName) : "";
    return host || null;
  } catch {
    return null;
  }
}

export function resetTailnetHostCacheForTest(): void {
  cachedHost = undefined;
}

export function tailnetHttpsOrigin(): string | null {
  const host = tailnetHost();
  return host ? `https://${host}` : null;
}
