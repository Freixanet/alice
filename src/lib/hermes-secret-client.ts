import { authHeaders } from "./auth/client";
import { cockpitUserId } from "./auth/cockpit-user";

const DEVICE_KEY = "alice-device-hermes-key";
const DEVICE_KEY_VERSION = 1;
let macSessionKey: string | null = null;

export function setMacSessionKey(key: string | null): void {
  macSessionKey = key;
}

export function getMacSessionKey(): string | null {
  return macSessionKey;
}

export function getDeviceSessionKey(): string | null {
  if (typeof sessionStorage === "undefined") return null;
  const raw = sessionStorage.getItem(DEVICE_KEY);
  if (!raw) return null;
  try {
    const stored = JSON.parse(raw) as {
      version?: unknown;
      userId?: unknown;
      key?: unknown;
    };
    const userId = cockpitUserId();
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
  sessionStorage.removeItem(DEVICE_KEY);
  return null;
}

export function setDeviceSessionKey(key: string | null): void {
  if (typeof sessionStorage === "undefined") return;
  const userId = cockpitUserId();
  if (key && userId) {
    sessionStorage.setItem(
      DEVICE_KEY,
      JSON.stringify({ version: DEVICE_KEY_VERSION, userId, key }),
    );
    return;
  }
  sessionStorage.removeItem(DEVICE_KEY);
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
