/**
 * Pure network rules for the temporary pairing helper. Kept outside pair.mjs
 * so the trust boundary is small, testable and independent of HTTP server I/O.
 *
 * V1 advertises an IPv4/hostname and accepts claims only from the same Mac or
 * the Tailscale CGNAT range. Long-lived Hermes credentials therefore never
 * cross an arbitrary LAN just because its address happens to be private.
 */

/**
 * A hostname or IPv4 suitable for interpolating into an http:// URL.
 * V1 intentionally leaves IPv6 literal formatting to a later protocol.
 */
export function advertisedHost(raw) {
  const value = String(raw ?? "").trim();
  if (!value || value.includes("/") || value.includes(":") || /\s/.test(value)) {
    return null;
  }
  try {
    const url = new URL(`http://${value}/`);
    return url.hostname.toLowerCase() === value.toLowerCase() ? value : null;
  } catch {
    return null;
  }
}

export function normalizedRemote(rawAddress) {
  return String(rawAddress ?? "")
    .replace(/^::ffff:/i, "")
    .toLowerCase();
}

export function isLoopback(rawAddress) {
  const address = normalizedRemote(rawAddress);
  return address === "::1" || address === "127.0.0.1";
}

/** Tailscale IPv4 uses RFC 6598's 100.64.0.0/10 range. */
export function isTailnet(rawAddress) {
  const address = normalizedRemote(rawAddress);
  const match = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(address);
  if (!match) return false;
  const octets = match.slice(1).map(Number);
  if (octets.some((value) => value < 0 || value > 255)) return false;
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

export function claimOriginAllowed(rawAddress) {
  return isLoopback(rawAddress) || isTailnet(rawAddress);
}
