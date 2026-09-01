import type { ClientOperationalEvent } from "./operational-telemetry";

export type ApiRoute =
  "/api/chat" | "/api/hermes" | "/api/phone" | "/api/sync" | "/api/telemetry";

export type ServerRequestOutcome =
  | "ok"
  | "bad_request"
  | "unauthorized"
  | "rate_limited"
  | "upstream_error"
  | "server_error"
  | "aborted";

export type ServerOperationalEvent = {
  kind: "server_request";
  route: ApiRoute;
  method: "GET" | "POST";
  status: number;
  outcome: ServerRequestOutcome;
  latencyMs: number;
};

type OperationalEvent = ClientOperationalEvent | ServerOperationalEvent;
type Sink = (line: string) => void;

const SUCCESS_SAMPLE_RATE = 0.1;
const MAX_EVENTS_PER_WINDOW = 600;
const EVENT_WINDOW_MS = 60_000;

let eventWindow = { startedAt: 0, count: 0 };

function deploymentVersion(): string {
  return (
    process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 12) ||
    process.env.ALICE_VERSION?.slice(0, 32) ||
    "development"
  );
}

export function serverRequestOutcome(
  status: number,
  aborted = false,
): ServerRequestOutcome {
  if (aborted) return "aborted";
  if (status < 400) return "ok";
  if (status === 401 || status === 403) return "unauthorized";
  if (status === 429) return "rate_limited";
  if (status >= 500 && status < 600) {
    return status === 502 || status === 503 || status === 504
      ? "upstream_error"
      : "server_error";
  }
  return "bad_request";
}

export function shouldRecordServerRequest(
  status: number,
  random = Math.random,
): boolean {
  return status >= 400 || random() < SUCCESS_SAMPLE_RATE;
}

export function consumeOperationalEventCapacity(now = Date.now()): boolean {
  if (
    eventWindow.startedAt === 0 ||
    now - eventWindow.startedAt >= EVENT_WINDOW_MS ||
    now < eventWindow.startedAt
  ) {
    eventWindow = { startedAt: now, count: 0 };
  }
  if (eventWindow.count >= MAX_EVENTS_PER_WINDOW) return false;
  eventWindow.count += 1;
  return true;
}

export function resetOperationalEventCapacityForTest(): void {
  eventWindow = { startedAt: 0, count: 0 };
}

export function recordOperationalEvent(
  event: OperationalEvent,
  sink?: Sink,
): void {
  if (
    !sink &&
    process.env.NODE_ENV !== "production" &&
    process.env.ALICE_TELEMETRY_ENABLED !== "1"
  ) {
    return;
  }
  (sink ?? console.info)(
    JSON.stringify({
      type: "alice_operational",
      version: deploymentVersion(),
      ...event,
    }),
  );
}

function withServerTiming(response: Response, latencyMs: number): Response {
  const headers = new Headers(response.headers);
  headers.append("Server-Timing", `alice;dur=${latencyMs}`);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function observeApiRequest<T extends { request: Request }>(
  route: ApiRoute,
  handler: (context: T) => Response | Promise<Response>,
  options: {
    now?: () => number;
    random?: () => number;
    sink?: Sink;
    record?: boolean;
  } = {},
): (context: T) => Promise<Response> {
  return async (context) => {
    const now = options.now ?? performance.now.bind(performance);
    const startedAt = now();
    try {
      const response = await handler(context);
      const latencyMs = Math.max(
        0,
        Math.round((now() - startedAt) * 100) / 100,
      );
      if (
        options.record !== false &&
        shouldRecordServerRequest(response.status, options.random)
      ) {
        recordOperationalEvent(
          {
            kind: "server_request",
            route,
            method: context.request.method === "GET" ? "GET" : "POST",
            status: response.status,
            outcome: serverRequestOutcome(response.status),
            latencyMs,
          },
          options.sink,
        );
      }
      return withServerTiming(response, latencyMs);
    } catch (error) {
      const aborted =
        context.request.signal.aborted ||
        (error instanceof Error && error.name === "AbortError");
      const latencyMs = Math.max(
        0,
        Math.round((now() - startedAt) * 100) / 100,
      );
      if (options.record !== false) {
        recordOperationalEvent(
          {
            kind: "server_request",
            route,
            method: context.request.method === "GET" ? "GET" : "POST",
            status: aborted ? 499 : 500,
            outcome: serverRequestOutcome(aborted ? 499 : 500, aborted),
            latencyMs,
          },
          options.sink,
        );
      }
      throw error;
    }
  };
}
