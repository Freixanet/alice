import { useEffect, useState } from "react";
import { listHermesLive, type HermesLive } from "./hermes-live";
import { useHermes } from "./store";

export function useHermesLive() {
  const live = useHermes((s) => s.gatewayOn && s.gatewayStatus === "live");
  const [data, setData] = useState<HermesLive | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const ctrl = new AbortController();
    setLoading(true);
    void listHermesLive({ signal: ctrl.signal }).then((result) => {
      if (ctrl.signal.aborted) return;
      if (!result.ok) {
        setError(result.error);
        setData(null);
        setLoading(false);
        return;
      }
      setError(null);
      setData(result);
      setLoading(false);
    });
    return () => ctrl.abort();
  }, [live]);

  return { data, error, loading, setData };
}
