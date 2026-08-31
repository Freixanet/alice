import { create } from "zustand";
import type { HermesLive, HermesLiveResult } from "./hermes-live-types";

export const HERMES_LIVE_CACHE_TTL_MS = 30_000;

type HermesLiveCacheEntry = {
  data: HermesLive | null;
  error: string | null;
  loading: boolean;
  updatedAt: number;
  revision: number;
};

type HermesLiveCacheState = {
  entries: Record<string, HermesLiveCacheEntry>;
};

export const useHermesLiveCache = create<HermesLiveCacheState>()(() => ({
  entries: {},
}));

const inFlight = new Map<string, Promise<void>>();
let generation = 0;

export function hermesLiveCacheKey(input: {
  userId: string;
  url: string;
  place: string;
  profile: string;
}) {
  return JSON.stringify([input.userId, input.place, input.url, input.profile]);
}

export function readHermesLiveCache(key: string) {
  return useHermesLiveCache.getState().entries[key];
}

function writeEntry(key: string, entry: HermesLiveCacheEntry) {
  useHermesLiveCache.setState((state) => ({
    entries: { ...state.entries, [key]: entry },
  }));
}

export function hermesLiveCacheGeneration() {
  return generation;
}

export function setHermesLiveCacheData(
  key: string,
  data: HermesLive,
  expectedGeneration = generation,
) {
  if (expectedGeneration !== generation) return false;
  const current = readHermesLiveCache(key);
  writeEntry(key, {
    data,
    error: null,
    loading: false,
    updatedAt: Date.now(),
    revision: (current?.revision ?? 0) + 1,
  });
  return true;
}

export function clearHermesLiveCache() {
  generation += 1;
  inFlight.clear();
  useHermesLiveCache.setState({ entries: {} });
}

export function refreshHermesLiveCache(
  key: string,
  load: () => Promise<HermesLiveResult>,
  options: { force?: boolean; now?: number } = {},
): Promise<void> {
  const now = options.now ?? Date.now();
  const current = readHermesLiveCache(key);
  if (
    !options.force &&
    current?.data &&
    now - current.updatedAt < HERMES_LIVE_CACHE_TTL_MS
  ) {
    return Promise.resolve();
  }
  const pending = inFlight.get(key);
  if (pending) return pending;

  const revision = current?.revision ?? 0;
  const requestGeneration = generation;
  writeEntry(key, {
    data: current?.data ?? null,
    error: current?.data ? null : (current?.error ?? null),
    loading: !current?.data,
    updatedAt: current?.updatedAt ?? 0,
    revision,
  });

  const request = Promise.resolve()
    .then(load)
    .then((result) => {
      if (requestGeneration !== generation) return;
      const latest = readHermesLiveCache(key);
      // An optimistic mutation made while this request was running is newer
      // than its snapshot and must never be overwritten by a stale response.
      if (latest && latest.revision !== revision) return;
      if (result.ok) {
        writeEntry(key, {
          data: result,
          error: null,
          loading: false,
          updatedAt: options.now ?? Date.now(),
          revision: revision + 1,
        });
        return;
      }
      writeEntry(key, {
        data: latest?.data ?? null,
        error: latest?.data ? null : result.error,
        loading: false,
        updatedAt: latest?.updatedAt ?? 0,
        revision,
      });
    })
    .catch(() => {
      if (requestGeneration !== generation) return;
      const latest = readHermesLiveCache(key);
      if (latest && latest.revision !== revision) return;
      writeEntry(key, {
        data: latest?.data ?? null,
        error: latest?.data ? null : "Couldn’t read Hermes status.",
        loading: false,
        updatedAt: latest?.updatedAt ?? 0,
        revision,
      });
    })
    .finally(() => {
      if (inFlight.get(key) === request) inFlight.delete(key);
    });
  inFlight.set(key, request);
  return request;
}
