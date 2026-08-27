import { execFileSync } from "node:child_process";

function stripDot(host: string): string {
  return host.replace(/\.$/, "").trim();
}

/** MagicDNS name for this Mac on the tailnet, or null if Tailscale is down. */
export function tailnetHost(): string | null {
  const fromEnv = process.env.ALICE_TAILNET_HOST?.trim();
  if (fromEnv) return stripDot(fromEnv);
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

export function tailnetHttpsOrigin(): string | null {
  const host = tailnetHost();
  return host ? `https://${host}` : null;
}
