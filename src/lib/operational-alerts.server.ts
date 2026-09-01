import type { ClientOperationalEvent } from "./operational-telemetry";

export type AlertRoute =
  | "/api/chat"
  | "/api/hermes"
  | "/api/phone"
  | "/api/status"
  | "/api/sync"
  | "/api/telemetry";

export type AlertableServerEvent = {
  kind: "server_request";
  route: AlertRoute;
  status: number;
  outcome:
    | "ok"
    | "bad_request"
    | "unauthorized"
    | "rate_limited"
    | "upstream_error"
    | "server_error"
    | "aborted";
  latencyMs: number;
};

export type AlertableOperationalEvent =
  ClientOperationalEvent | AlertableServerEvent;

export type OperationalAlertCode =
  | "auth_failure_burst"
  | "client_error_burst"
  | "handler_latency"
  | "hermes_connection_failure_burst"
  | "server_failure"
  | "sync_failure"
  | "web_vital_budget_exceeded";

export type OperationalAlert = {
  type: "alice_alert";
  code: OperationalAlertCode;
  severity: "warning" | "critical";
  count: number;
  windowMs: number;
  route?: AlertRoute;
  metric?: "lcp" | "inp" | "cls";
};

type AlertCandidate = Omit<OperationalAlert, "type" | "count" | "windowMs"> & {
  threshold: number;
};

const WINDOW_MS = 60_000;
const COOLDOWN_MS = 60_000;

function webVitalCandidate(
  event: Extract<ClientOperationalEvent, { kind: "web_vital" }>,
): AlertCandidate | undefined {
  const value = event.metric === "cls" ? event.value : event.latencyMs;
  const warning =
    event.metric === "lcp" ? 2_500 : event.metric === "inp" ? 200 : 0.1;
  const critical =
    event.metric === "lcp" ? 4_000 : event.metric === "inp" ? 500 : 0.25;
  if (value <= warning) return undefined;
  return {
    code: "web_vital_budget_exceeded",
    severity: value > critical ? "critical" : "warning",
    metric: event.metric,
    threshold: 1,
  };
}

function serverCandidate(
  event: AlertableServerEvent,
): AlertCandidate | undefined {
  if (event.route === "/api/sync" && event.status >= 500) {
    return {
      code: "sync_failure",
      severity: "critical",
      route: event.route,
      threshold: 1,
    };
  }
  if (event.outcome === "server_error") {
    return {
      code: "server_failure",
      severity: "critical",
      route: event.route,
      threshold: 1,
    };
  }
  if (event.route === "/api/hermes" && event.outcome === "upstream_error") {
    return {
      code: "hermes_connection_failure_burst",
      severity: "warning",
      route: event.route,
      threshold: 3,
    };
  }
  if (event.outcome === "unauthorized") {
    return {
      code: "auth_failure_burst",
      severity: "warning",
      route: event.route,
      threshold: 10,
    };
  }
  const excludesUpstreamLatency =
    event.route === "/api/chat" || event.route === "/api/hermes";
  if (!excludesUpstreamLatency && event.latencyMs > 500) {
    return {
      code: "handler_latency",
      severity: event.latencyMs > 2_000 ? "critical" : "warning",
      route: event.route,
      threshold: event.latencyMs > 2_000 ? 1 : 3,
    };
  }
  return undefined;
}

function candidateFor(
  event: AlertableOperationalEvent,
): AlertCandidate | undefined {
  if (event.kind === "web_vital") return webVitalCandidate(event);
  if (event.kind === "client_error") {
    if (event.code === "hermes_connection_error") {
      return {
        code: "hermes_connection_failure_burst",
        severity: "warning",
        threshold: 3,
      };
    }
    return {
      code: "client_error_burst",
      severity: "warning",
      threshold: 5,
    };
  }
  if (event.kind === "server_request") return serverCandidate(event);
  return undefined;
}

type AlertState = {
  windowStartedAt: number;
  count: number;
  lastEmittedAt?: number;
};

export class OperationalAlertMonitor {
  private readonly states = new Map<string, AlertState>();

  observe(
    event: AlertableOperationalEvent,
    now = Date.now(),
  ): OperationalAlert | undefined {
    const candidate = candidateFor(event);
    if (!candidate) return undefined;
    const key = [
      candidate.code,
      candidate.severity,
      candidate.route,
      candidate.metric,
    ].join(":");
    const prior = this.states.get(key);
    const state =
      !prior ||
      now < prior.windowStartedAt ||
      now - prior.windowStartedAt >= WINDOW_MS
        ? {
            windowStartedAt: now,
            count: 0,
            ...(prior?.lastEmittedAt === undefined
              ? {}
              : { lastEmittedAt: prior.lastEmittedAt }),
          }
        : prior;
    state.count += 1;
    this.states.set(key, state);
    if (state.count < candidate.threshold) return undefined;
    if (
      state.lastEmittedAt !== undefined &&
      now >= state.lastEmittedAt &&
      now - state.lastEmittedAt < COOLDOWN_MS
    ) {
      return undefined;
    }
    state.lastEmittedAt = now;
    return {
      type: "alice_alert",
      code: candidate.code,
      severity: candidate.severity,
      count: state.count,
      windowMs: WINDOW_MS,
      ...(candidate.route ? { route: candidate.route } : {}),
      ...(candidate.metric ? { metric: candidate.metric } : {}),
    };
  }

  reset(): void {
    this.states.clear();
  }
}
