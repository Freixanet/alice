import { readSse, type ChatEvent } from "./gateway";
import {
  buildHermesRunRequest,
  eventsFromHermesRunChunk,
  eventsFromHermesRunSnapshot,
  isTerminalHermesRunStatus,
  parseHermesRunSnapshot,
  parseHermesRunStart,
  type HermesRunSnapshot,
  type HermesRunTurn,
} from "./hermes-runs";
import type { HermesApprovalChoice } from "./gateway-contracts";

type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

export type StartedHermesRun = {
  runId: string;
  status: "started" | "queued" | "running";
};

export type StartHermesRunResult =
  | { ok: true; run: StartedHermesRun }
  | { ok: false; unsupported: boolean; status: number; message: string };

type HermesRunTransport = {
  fetch: FetchLike;
  base: string;
  token: string;
  signal: AbortSignal;
};

export async function startHermesRun(
  opts: HermesRunTransport & {
    messages: HermesRunTurn[];
    conversationId?: string;
    model?: string;
    provider?: string;
  },
): Promise<StartHermesRunResult> {
  const body = buildHermesRunRequest(opts);
  if (!body) {
    return {
      ok: false,
      unsupported: false,
      status: 400,
      message: "Empty chat.",
    };
  }
  const post = (payload: Record<string, unknown>) =>
    opts.fetch(`${opts.base}/v1/runs`, {
      method: "POST",
      headers: runHeaders(opts.token, opts.conversationId, {
        "Content-Type": "application/json",
      }),
      body: JSON.stringify(payload),
      signal: opts.signal,
      cache: "no-store",
      redirect: "manual",
    });
  let response = await post(body);
  if (
    !response.ok &&
    (response.status === 400 || response.status === 422) &&
    (body.model !== "hermes-agent" || body.provider)
  ) {
    const fallback: Record<string, unknown> = {
      ...body,
      model: "hermes-agent",
    };
    delete fallback.provider;
    response = await post(fallback);
  }
  if (!response.ok) {
    return {
      ok: false,
      unsupported: [404, 405, 501].includes(response.status),
      status: response.status,
      message: await responseError(response),
    };
  }
  const run = parseHermesRunStart(await safeJson(response));
  if (!run) {
    return {
      ok: false,
      unsupported: false,
      status: 502,
      message: "Hermes returned an invalid run identifier.",
    };
  }
  return {
    ok: true,
    run: {
      runId: run.runId,
      status:
        run.status === "queued" || run.status === "running"
          ? run.status
          : "started",
    },
  };
}

export async function* streamStartedHermesRun(
  opts: HermesRunTransport & {
    run: StartedHermesRun;
    conversationId?: string;
  },
): AsyncGenerator<ChatEvent> {
  yield { type: "run", runId: opts.run.runId, status: opts.run.status };
  let terminal = false;
  try {
    const response = await opts.fetch(
      `${opts.base}/v1/runs/${encodeURIComponent(opts.run.runId)}/events`,
      {
        headers: runHeaders(opts.token, opts.conversationId, {
          Accept: "text/event-stream",
        }),
        signal: opts.signal,
        cache: "no-store",
        redirect: "manual",
      },
    );
    if (!response.ok || !response.body) {
      throw new Error(await responseError(response));
    }
    for await (const chunk of readSse(response.body)) {
      for (const event of eventsFromHermesRunChunk(chunk)) {
        yield event;
        if (event.type === "run" && isTerminalHermesRunStatus(event.status)) {
          terminal = true;
        }
      }
    }
  } catch (error) {
    if (opts.signal.aborted) throw error;
  }

  if (terminal || opts.signal.aborted) return;
  const snapshot = await waitForHermesRun({
    ...opts,
    runId: opts.run.runId,
  });
  if (!snapshot) {
    yield {
      type: "error",
      message:
        "Alice lost the live connection to Hermes. Reopen this chat to recover it.",
    };
    return;
  }
  for (const event of eventsFromHermesRunSnapshot(snapshot)) yield event;
}

export async function getHermesRunSnapshot(
  opts: HermesRunTransport & { runId: string; conversationId?: string },
): Promise<HermesRunSnapshot | null> {
  const response = await opts.fetch(
    `${opts.base}/v1/runs/${encodeURIComponent(opts.runId)}`,
    {
      headers: runHeaders(opts.token, opts.conversationId),
      signal: opts.signal,
      cache: "no-store",
      redirect: "manual",
    },
  );
  if (!response.ok) return null;
  return parseHermesRunSnapshot(await safeJson(response));
}

export async function controlHermesRun(
  opts: HermesRunTransport &
    (
      | { action: "stop"; runId: string }
      | {
          action: "approval";
          runId: string;
          choice: HermesApprovalChoice;
          resolveAll?: boolean;
        }
    ),
): Promise<boolean> {
  const suffix = opts.action === "stop" ? "stop" : "approval";
  const response = await opts.fetch(
    `${opts.base}/v1/runs/${encodeURIComponent(opts.runId)}/${suffix}`,
    {
      method: "POST",
      headers: runHeaders(opts.token, undefined, {
        "Content-Type": "application/json",
      }),
      body:
        opts.action === "approval"
          ? JSON.stringify({
              choice: opts.choice,
              resolve_all: opts.resolveAll,
            })
          : "{}",
      signal: opts.signal,
      cache: "no-store",
      redirect: "manual",
    },
  );
  return response.ok;
}

async function waitForHermesRun(
  opts: HermesRunTransport & { runId: string; conversationId?: string },
): Promise<HermesRunSnapshot | null> {
  const deadline = Date.now() + 180_000;
  while (!opts.signal.aborted && Date.now() < deadline) {
    const snapshot = await getHermesRunSnapshot(opts).catch(() => null);
    if (snapshot && isTerminalHermesRunStatus(snapshot.status)) return snapshot;
    await abortableDelay(750, opts.signal);
  }
  return null;
}

function runHeaders(
  token: string,
  conversationId?: string,
  extra?: Record<string, string>,
): HeadersInit {
  return {
    Authorization: `Bearer ${token}`,
    "X-Hermes-Session-Token": token,
    Accept: "application/json",
    ...(conversationId
      ? { "X-Hermes-Session-Key": conversationId.slice(0, 128) }
      : {}),
    ...extra,
  };
}

async function safeJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

async function responseError(response: Response): Promise<string> {
  const body = await safeJson(response);
  if (body && typeof body === "object" && !Array.isArray(body)) {
    const record = body as Record<string, unknown>;
    const nested =
      record.error &&
      typeof record.error === "object" &&
      !Array.isArray(record.error)
        ? (record.error as Record<string, unknown>)
        : null;
    const message =
      (typeof nested?.message === "string" && nested.message) ||
      (typeof record.error === "string" && record.error) ||
      (typeof record.message === "string" && record.message);
    if (message) return message.slice(0, 8_000);
  }
  return "Couldn’t connect.";
}

function abortableDelay(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(signal.reason);
      return;
    }
    const onAbort = () => {
      clearTimeout(timeout);
      reject(signal.reason);
    };
    const timeout = windowlessSetTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

const windowlessSetTimeout = globalThis.setTimeout.bind(globalThis);
