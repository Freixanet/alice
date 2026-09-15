import { authHeaders } from "./auth/client";
import { cockpitUserId } from "./auth/cockpit-user";

const DEVICE_KEY = "alice-device-hermes-key";
const DEVICE_KEY_VERSION = 1;
let macSessionKey: string | null = null;
type DeviceSecret = { version: number; userId: string; key: string };
// Memory remains usable when the browser blocks storage. `null` also records
// an explicit forget so a failed removeItem cannot resurrect an old key.
let deviceSecret: DeviceSecret | null | undefined;

export function setMacSessionKey(key: string | null): void {
  macSessionKey = key;
}

export function getMacSessionKey(): string | null {
  return macSessionKey;
}

export function getDeviceSessionKey(): string | null {
  const userId = cockpitUserId();
  if (deviceSecret !== undefined) {
    if (deviceSecret && userId && deviceSecret.userId === userId)
      return deviceSecret.key;
    setDeviceSessionKey(null);
    return null;
  }
  try {
    const raw = sessionStorage.getItem(DEVICE_KEY);
    if (!raw) return null;
    const stored = JSON.parse(raw) as {
      version?: unknown;
      userId?: unknown;
      key?: unknown;
    };
    if (
      stored.version === DEVICE_KEY_VERSION &&
      userId &&
      stored.userId === userId &&
      typeof stored.key === "string" &&
      stored.key
    ) {
      return stored.key;
    }
  } catch {
    // Unscoped legacy values are deliberately discarded instead of being
    // attributed to whichever account happens to sign in next.
  }
  setDeviceSessionKey(null);
  return null;
}

export function setDeviceSessionKey(key: string | null): void {
  const userId = cockpitUserId();
  deviceSecret =
    key && userId ? { version: DEVICE_KEY_VERSION, userId, key } : null;
  try {
    if (deviceSecret)
      sessionStorage.setItem(DEVICE_KEY, JSON.stringify(deviceSecret));
    else sessionStorage.removeItem(DEVICE_KEY);
  } catch {
    // Private browsing, quotas or storage policy must not interrupt connection
    // or prevent the authenticated server-side forget request below.
  }
}

export async function forgetHermesSecret(): Promise<void> {
  setMacSessionKey(null);
  setDeviceSessionKey(null);
  try {
    await fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "forget" }),
    });
  } catch {
    // Clearing both in-memory secrets is sufficient while offline.
  }
}
