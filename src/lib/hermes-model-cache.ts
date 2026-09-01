import type { HermesModelOption } from "./gateway";
import { SharedReadCache } from "./shared-read-cache";

export type HermesModelReadResult = {
  ok: boolean;
  models: HermesModelOption[];
  currentModel?: string;
  currentProvider?: string;
};

const modelReads = new SharedReadCache<HermesModelReadResult>(
  30_000,
  (result) => result.ok,
);

export function hermesModelCacheKey(input: {
  userId: string;
  url: string;
  place: string;
  profile: string;
}): string {
  return JSON.stringify([input.userId, input.place, input.url, input.profile]);
}

export function readHermesModelsCached(
  key: string,
  load: (signal: AbortSignal) => Promise<HermesModelReadResult>,
  options: { force?: boolean; signal?: AbortSignal } = {},
): Promise<HermesModelReadResult> {
  return modelReads.read(key, load, options);
}

export function invalidateHermesModelCache(key: string): void {
  modelReads.invalidate(key);
}

export function clearHermesModelCache(): void {
  modelReads.clear();
}
