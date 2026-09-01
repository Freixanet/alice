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
  let vitalsReported = false;
  let lcp: number | undefined;
  let inp: number | undefined;
  let cls = 0;
  let observesCls = false;
  const observers: PerformanceObserver[] = [];

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
  const reportWebVitals = () => {
    if (vitalsReported) return;
    vitalsReported = true;
    if (lcp !== undefined) {
      reportOperationalEvent({
        kind: "web_vital",
        ...context(),
        metric: "lcp",
        latencyMs: boundedLatency(lcp),
      });
    }
    if (inp !== undefined) {
      reportOperationalEvent({
        kind: "web_vital",
        ...context(),
        metric: "inp",
        latencyMs: boundedLatency(inp),
      });
    }
    if (observesCls) {
      reportOperationalEvent({
        kind: "web_vital",
        ...context(),
        metric: "cls",
        value: Math.min(10, Math.max(0, Math.round(cls * 10_000) / 10_000)),
      });
    }
  };
  const flushWhenHidden = () => {
    if (document.visibilityState === "hidden") reportWebVitals();
  };

  if (typeof PerformanceObserver !== "undefined") {
    const supported = PerformanceObserver.supportedEntryTypes;
    if (supported.includes("largest-contentful-paint")) {
      const observer = new PerformanceObserver((list) => {
        const last = list.getEntries().at(-1);
        if (last) lcp = last.startTime;
      });
      observer.observe({ type: "largest-contentful-paint", buffered: true });
      observers.push(observer);
    }
    if (supported.includes("layout-shift")) {
      observesCls = true;
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as LayoutShiftEntry[]) {
          if (!entry.hadRecentInput) cls += entry.value;
        }
      });
      observer.observe({ type: "layout-shift", buffered: true });
      observers.push(observer);
    }
    if (supported.includes("event")) {
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as EventTimingEntry[]) {
          if (entry.interactionId > 0) inp = Math.max(inp ?? 0, entry.duration);
        }
      });
      observer.observe({
        type: "event",
        buffered: true,
        durationThreshold: 16,
      } as PerformanceObserverInit);
      observers.push(observer);
    }
  }

  if (document.readyState === "complete") {
    queueMicrotask(reportNavigation);
  } else {
    window.addEventListener("load", reportNavigation, { once: true });
  }
  window.addEventListener("error", reportRuntimeError);
  window.addEventListener("unhandledrejection", reportUnhandledRejection);
  document.addEventListener("visibilitychange", flushWhenHidden);
  window.addEventListener("pagehide", reportWebVitals);

  return () => {
    for (const observer of observers) observer.disconnect();
    window.removeEventListener("load", reportNavigation);
    window.removeEventListener("error", reportRuntimeError);
    window.removeEventListener("unhandledrejection", reportUnhandledRejection);
    document.removeEventListener("visibilitychange", flushWhenHidden);
    window.removeEventListener("pagehide", reportWebVitals);
  };
}

type LayoutShiftEntry = PerformanceEntry & {
  value: number;
  hadRecentInput: boolean;
};

type EventTimingEntry = PerformanceEntry & {
  duration: number;
  interactionId: number;
};
