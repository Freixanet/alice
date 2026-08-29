import { useEffect } from "react";
import { authHeaders } from "./auth/client";
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
    let timer: number | undefined;

    function schedule(ms: number) {
      if (!ctrl.signal.aborted) timer = window.setTimeout(() => void check(), ms);
    }

    async function check() {
      const alreadyLive = useHermes.getState().gatewayStatus === "live";
      if (!alreadyLive) setChecking();
      if (place !== "device") {
        try {
          const res = await fetch("/api/hermes", {
            method: "POST",
            headers: authHeaders({ "Content-Type": "application/json" }),
            body: JSON.stringify({ action: "status" }),
            signal: ctrl.signal,
          });
          const data = (await res.json()) as { hasKey?: boolean };
          if (ctrl.signal.aborted) return;
          if (!data.hasKey) {
            setDown("Go back to Connect and paste the Hermes key.");
            schedule(30_000);
            return;
          }
        } catch {
          if (ctrl.signal.aborted) return;
        }
      }
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
        schedule(60_000);
        return;
      }
      if (!(alreadyLive && (result.code === "unreachable" || result.code === "cors"))) {
        setDown(result.error);
      }
      schedule(15_000);
    }

    void check();
    return () => {
      ctrl.abort();
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [hydrated, on, url, place, setChecking, setLive, setDown, setGatewayModels]);
}
