export type GatewayMode = "direct" | "proxy";

export type GatewayPlace = "cloud" | "mac" | "device";

export type GatewayStatus = "idle" | "checking" | "live" | "down";

export type HermesModelOption = {
  id: string;
  label: string;
  provider: string;
  providerName?: string;
};

export type GatewayMeta = {
  model: string;
  provider?: string;
  models?: HermesModelOption[];
  platform?: string;
  skills?: string[];
  probedAt: number;
  mode: GatewayMode;
  place?: GatewayPlace;
};

export type ChatEvent =
  | { type: "delta"; text: string }
  | {
      type: "tool";
      name: string;
      status: "start" | "done";
      detail?: string;
      callId?: string;
    }
  | { type: "error"; message: string };

export type HermesChatContent =
  | string
  | Array<
      | { type: "text"; text: string }
      | {
          type: "image_url";
          image_url: { url: string; detail?: "auto" | "low" | "high" };
        }
    >;

export type ProbeCode =
  | "invalid"
  | "private"
  | "unauthorized"
  | "unreachable"
  | "cors"
  | "not_hermes";

export type ProbeResult =
  | {
      ok: true;
      model: string;
      provider?: string;
      models?: HermesModelOption[];
      platform?: string;
      skills?: string[];
      mode: GatewayMode;
    }
  | { ok: false; code: ProbeCode; error: string };

export function unionHermesModels(
  current: HermesModelOption[] | undefined,
  incoming: HermesModelOption[],
): HermesModelOption[] {
  const out: HermesModelOption[] = [];
  const seen = new Set<string>();
  for (const item of [...incoming, ...(current ?? [])]) {
    const key = `${item.provider}:${item.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
    if (out.length >= 400) break;
  }
  return out;
}
