import { useCallback, useEffect } from "react";
import { cockpitUserId } from "./auth/cockpit-user";
import { listHermesLive, type HermesLive } from "./hermes-live";
import {
  hermesLiveCacheGeneration,
  hermesLiveCacheKey,
  refreshHermesLiveCache,
  setHermesLiveCacheData,
  useHermesLiveCache,
} from "./hermes-live-cache";
import { useHermes } from "./store";

export function useHermesLive() {
  const live = useHermes((s) => s.gatewayOn && s.gatewayStatus === "live");
  const url = useHermes((s) => s.gatewayUrl);
  const place = useHermes((s) => s.gatewayPlace);
  const profile = useHermes((s) => s.profile);
  const key = live
    ? hermesLiveCacheKey({
        userId: cockpitUserId() ?? "anonymous",
        url,
        place,
        profile,
      })
    : null;
  const entry = useHermesLiveCache((state) =>
    key ? state.entries[key] : undefined,
  );
  const cacheGeneration = hermesLiveCacheGeneration();

  useEffect(() => {
    if (!key) return;
    // This request intentionally survives route unmounts. A page opened while
    // it is running reuses the same promise instead of restarting the work.
    void refreshHermesLiveCache(key, () => listHermesLive());
  }, [key]);

  const setData = useCallback(
    (data: HermesLive) => {
      if (key) setHermesLiveCacheData(key, data, cacheGeneration);
    },
    [cacheGeneration, key],
  );

  if (!live || !key) {
    return { data: null, error: null, loading: false, setData };
  }
  return {
    data: entry?.data ?? null,
    error: entry?.error ?? null,
    loading: entry?.data ? false : (entry?.loading ?? true),
    setData,
  };
}
