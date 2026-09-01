import { authHeaders } from "./auth/client";

export type HermesGateStatus = {
  owner: boolean;
  local: boolean;
  hasKey: boolean;
  url?: string;
  place?: "cloud" | "mac" | "device";
};

export async function readHermesGateStatus(
  signal?: AbortSignal,
): Promise<HermesGateStatus> {
  const response = await fetch("/api/hermes", {
    method: "POST",
    headers: authHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ action: "status" }),
    ...(signal === undefined ? {} : { signal }),
    cache: "no-store",
  });
  if (!response.ok) throw new Error("gate-status");
  const data = (await response.json()) as Partial<HermesGateStatus>;
  return {
    owner: Boolean(data.owner),
    local: Boolean(data.local),
    hasKey: Boolean(data.hasKey),
    ...(typeof data.url === "string" ? { url: data.url } : {}),
    ...(data.place === "cloud" ||
    data.place === "mac" ||
    data.place === "device"
      ? { place: data.place }
      : {}),
  };
}

export function savedGatewayFromStatus(status: HermesGateStatus):
  | {
      url: string;
      place: "cloud" | "mac" | "device";
    }
  | undefined {
  if (!status.hasKey || !status.url || !status.place) return undefined;
  return { url: status.url, place: status.place };
}

export function gatewayRestoreDelay(attempt: number): number {
  const safeAttempt = Number.isFinite(attempt)
    ? Math.max(0, Math.floor(attempt))
    : 0;
  return Math.min(15_000, 1_000 * 2 ** Math.min(safeAttempt, 4));
}
