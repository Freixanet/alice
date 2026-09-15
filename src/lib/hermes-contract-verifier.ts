import {
  parseHermesCapabilityManifest,
  parseHermesVersion,
  type HermesCapabilityManifest,
} from "./gateway-contracts";
import { assertGatewayKey, normalizeGatewayUrl } from "./gateway";

type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

export type HermesLiveContractResult =
  | {
      ok: true;
      version: string;
      manifest: HermesCapabilityManifest;
      models: number;
      skills: number;
      toolsets: number;
    }
  | { ok: false; error: string };

export async function verifyLiveHermesContract(opts: {
  url: string;
  key: string;
  fetcher?: FetchLike;
  signal?: AbortSignal;
}): Promise<HermesLiveContractResult> {
  try {
    const base = normalizeGatewayUrl(opts.url);
    const token = assertGatewayKey(opts.key);
    const fetcher = opts.fetcher ?? fetch;
    const signal = opts.signal ?? AbortSignal.timeout(20_000);
    const headers = {
      Authorization: `Bearer ${token}`,
      "X-Hermes-Session-Token": token,
      Accept: "application/json",
    };
    const [health, capabilities, models, skills, toolsets] = await Promise.all([
      readJson(fetcher, `${base}/health/detailed`, headers, signal),
      readJson(fetcher, `${base}/v1/capabilities`, headers, signal),
      readJson(fetcher, `${base}/v1/models`, headers, signal),
      readJson(fetcher, `${base}/v1/skills`, headers, signal),
      readJson(fetcher, `${base}/v1/toolsets`, headers, signal),
    ]);
    const version = parseHermesVersion(readVersion(health));
    if (version.normalized === null || version.compatibility === "unknown") {
      return {
        ok: false,
        error: version.raw
          ? `Hermes ${version.raw} is outside Alice’s supported version window.`
          : "Hermes didn’t report a version in its detailed health response.",
      };
    }
    const manifest = parseHermesCapabilityManifest({
      ...asRecord(capabilities),
      version: version.normalized,
    });
    for (const capability of [
      "chat.streaming",
      "chat.runs",
      "chat.cancel",
      "models",
      "skills",
      "toolsets",
      "sessions",
    ] as const) {
      if (!manifest.capabilities[capability]) {
        return {
          ok: false,
          error: `Hermes ${version.normalized} didn’t advertise ${capability}.`,
        };
      }
    }
    return {
      ok: true,
      version: version.normalized,
      manifest,
      models: listLength(models, ["data", "models"]),
      skills: listLength(skills, ["skills", "data"]),
      toolsets: listLength(toolsets, ["toolsets", "data"]),
    };
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof Error && error.name === "AbortError"
          ? "Hermes contract verification timed out."
          : "Hermes contract verification failed.",
    };
  }
}

async function readJson(
  fetcher: FetchLike,
  url: string,
  headers: HeadersInit,
  signal: AbortSignal,
): Promise<unknown> {
  const response = await fetcher(url, {
    headers,
    signal,
    cache: "no-store",
    redirect: "manual",
  });
  if (!response.ok) {
    throw new Error(`Hermes contract endpoint returned ${response.status}.`);
  }
  return response.json();
}

function readVersion(value: unknown): string | null {
  const record = asRecord(value);
  if (typeof record.version === "string") return record.version;
  const readiness = asRecord(record.readiness);
  return typeof readiness.version === "string" ? readiness.version : null;
}

function listLength(value: unknown, keys: string[]): number {
  if (Array.isArray(value)) return value.length;
  const record = asRecord(value);
  for (const key of keys) {
    if (Array.isArray(record[key])) return record[key].length;
  }
  return 0;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}
