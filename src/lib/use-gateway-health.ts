import { useEffect } from "react";
import { getMacSessionKey, listHermesModels, probeGateway } from "./gateway";
import { getDeviceSessionKey } from "./hermes-direct";
import { useHermes } from "./store";

export function useGatewayHealth() {
  const hydrated = useHermes((s) => s.hydrated);
  const on = useHermes((s) => s.gatewayOn);
  const url = useHermes((s) => s.gatewayUrl);
  const place = useHermes((s) => s.gatewayPlace);
  const setChecking = useHermes((s) => s.setGatewayChecking);
  const setLive = useHermes((s) => s.setGatewayLive);
  const setDown = useHermes((s) => s.setGatewayDown);
  const setGatewayModels = useHermes((s) => s.setGatewayModels);

  useEffect(() => {
    if (!hydrated) return;
    if (!on || !url) return;
    const ctrl = new AbortController();
    const alreadyLive = useHermes.getState().gatewayStatus === "live";
    if (!alreadyLive) setChecking();
    void (async () => {
      const result = await probeGateway({
        url,
        key:
          place === "mac"
            ? getMacSessionKey() ?? undefined
            : place === "device"
              ? getDeviceSessionKey() ?? undefined
              : undefined,
        place,
        save: false,
        signal: ctrl.signal,
      });
      if (ctrl.signal.aborted) return;
      if (result.ok) {
        setLive({
          model: result.model,
          provider: result.provider,
          models: result.models,
          platform: result.platform,
          skills: result.skills,
          probedAt: Date.now(),
          mode: result.mode,
          place,
        });
        const listed = await listHermesModels({ refresh: true, signal: ctrl.signal });
        if (!ctrl.signal.aborted && listed.ok) setGatewayModels(listed.models);
        return;
      }
      if (alreadyLive && result.code !== "unauthorized") return;
      setDown(result.error);
    })();
    return () => ctrl.abort();
  }, [hydrated, on, url, place, setChecking, setLive, setDown, setGatewayModels]);
}
