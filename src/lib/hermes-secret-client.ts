import { authHeaders } from "./auth/client";

const DEVICE_KEY = "alice-device-hermes-key";
let macSessionKey: string | null = null;

export function setMacSessionKey(key: string | null): void {
  macSessionKey = key;
}

export function getMacSessionKey(): string | null {
  return macSessionKey;
}

export function getDeviceSessionKey(): string | null {
  if (typeof sessionStorage === "undefined") return null;
  return sessionStorage.getItem(DEVICE_KEY);
}

export function setDeviceSessionKey(key: string | null): void {
  if (typeof sessionStorage === "undefined") return;
  if (key) sessionStorage.setItem(DEVICE_KEY, key);
  else sessionStorage.removeItem(DEVICE_KEY);
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
