import {
  boundedLatency,
  browserFamily,
  clientOperationalEventSchema,
  normalizeOperationalRoute,
  viewportBucket,
  type ClientOperationalEvent,
} from "./operational-telemetry";

function context() {
  return {
    route: normalizeOperationalRoute(window.location.pathname),
    browser: browserFamily(window.navigator.userAgent),
    viewport: viewportBucket(window.innerWidth),
  } as const;
}

export function reportClientError(
  code: "runtime_error" | "unhandled_rejection" | "route_error",
): void {
  reportOperationalEvent({
    kind: "client_error",
    ...context(),
    code,
  });
}

export function reportOperationalEvent(event: ClientOperationalEvent): void {
  const parsed = clientOperationalEventSchema.safeParse(event);
  if (!parsed.success) return;
  void fetch("/api/telemetry", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(parsed.data),
    credentials: "omit",
    keepalive: true,
    referrerPolicy: "origin",
  }).catch(() => undefined);
}

export function installOperationalTelemetry(): () => void {
  let navigationReported = false;

  const reportNavigation = () => {
    if (navigationReported) return;
    navigationReported = true;
    const navigation = performance.getEntriesByType("navigation")[0] as
      PerformanceNavigationTiming | undefined;
    reportOperationalEvent({
      kind: "navigation",
      ...context(),
      latencyMs: boundedLatency(navigation?.duration ?? performance.now()),
    });
  };
  const reportRuntimeError = () => {
    reportClientError("runtime_error");
  };
  const reportUnhandledRejection = () => {
    reportClientError("unhandled_rejection");
  };

  if (document.readyState === "complete") {
    queueMicrotask(reportNavigation);
  } else {
    window.addEventListener("load", reportNavigation, { once: true });
  }
  window.addEventListener("error", reportRuntimeError);
  window.addEventListener("unhandledrejection", reportUnhandledRejection);

  return () => {
    window.removeEventListener("load", reportNavigation);
    window.removeEventListener("error", reportRuntimeError);
    window.removeEventListener("unhandledrejection", reportUnhandledRejection);
  };
}
