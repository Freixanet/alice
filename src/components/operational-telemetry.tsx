import { useEffect } from "react";

export function OperationalTelemetry() {
  useEffect(() => {
    let disposed = false;
    let uninstall: (() => void) | undefined;
    void import("@/lib/operational-telemetry-client")
      .then(({ installOperationalTelemetry }) => {
        if (!disposed) uninstall = installOperationalTelemetry();
      })
      .catch(() => undefined);
    return () => {
      disposed = true;
      uninstall?.();
    };
  }, []);
  return null;
}
