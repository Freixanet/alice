export * from "./gateway.server.legacy";

import { classifyModelLimit } from "./model-limit";
import { resolveChatModelFallback } from "./model-fallback";
import { pinnedFetch as fetch } from "./outbound-http.server";
import {
  assertGatewayKey,
  eventFromChunk,
  readSse,
  scopeHermesGatewayBase,
  type ChatEvent,
  type GatewayPlace,
  type HermesChatContent,
} from "./gateway";
import { startHermesRun, streamStartedHermesRun } from "./hermes-run-transport";
import { whenDefined } from "./exact-optional";
import {
  matchStoredEndpoint,
  ndjsonResponse,
  resolveHermesBase,
  type StoredEndpoint,
} from "./gateway.server.legacy";

const FAIL = "Couldn’t connect.";

type ChatTurn = { role: "user" | "assistant"; content: HermesChatContent };

function hermesHeaders(
  key: string,
  extra?: Record<string, string>,
): HeadersInit {
  return {
    Authorization: `Bearer ${key}`,
    "X-Hermes-Session-Token": key,
    Accept: "application/json",
    ...extra,
  };
}

async function hermesJson(
  res: Response,
): Promise<Record<string, unknown> | null> {
  try {
    const body = await res.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? (body as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function hermesDetail(
  body: Record<string, unknown> | null,
  fallback = FAIL,
): string {
  if (!body) return fallback;
  if (typeof body.detail === "string" && body.detail.trim())
    return body.detail.trim();
  if (Array.isArray(body.detail)) {
    const parts = body.detail
      .map((item) => {
        if (typeof item === "string") return item;
        if (item && typeof item === "object" && !Array.isArray(item)) {
          const rec = item as Record<string, unknown>;
          if (typeof rec.msg === "string") return rec.msg;
        }
        return "";
      })
      .filter(Boolean);
    if (parts.length) return parts.join(" ");
  }
  if (typeof body.message === "string" && body.message.trim())
    return body.message.trim();
  if (typeof body.error === "string" && body.error.trim())
    return body.error.trim();
  if (
    body.error &&
    typeof body.error === "object" &&
    !Array.isArray(body.error)
  ) {
    const nested = body.error as Record<string, unknown>;
    if (typeof nested.message === "string" && nested.message.trim()) {
      return nested.message.trim();
    }
  }
  return fallback;
}

/**
 * OpenAI-compatible Hermes chat transport with a deliberately narrow fallback:
 * only an identified model/provider incompatibility may retry as Hermes Agent.
 * Authentication, quota/rate limits and transient service failures are returned
 * unchanged, and a successful fallback emits a visible model-fallback event.
 */
export async function streamHermesProxy(opts: {
  url: string;
  key: string;
  messages: ChatTurn[];
  conversationId?: string;
  model?: string;
  provider?: string;
  preferRuns?: boolean;
  runIdempotency?: boolean;
  endpoints?: StoredEndpoint[];
  signal: AbortSignal;
  place?: GatewayPlace;
  profile?: string;
}): Promise<Response> {
  const base = scopeHermesGatewayBase(
    await resolveHermesBase(opts.url, opts.place),
    opts.profile,
  );
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  const custom = matchStoredEndpoint(
    opts.endpoints,
    opts.model,
    opts.provider,
    opts.profile,
  );
  const requestedModel = custom?.d
    ? "hermes-agent"
    : opts.model?.trim() || "hermes-agent";
  const requestedProvider = custom?.d ? "" : opts.provider?.trim() || "";

  if (opts.preferRuns && !custom) {
    const started = await startHermesRun({
      fetch,
      base,
      token,
      signal,
      messages: opts.messages,
      ...whenDefined("conversationId", opts.conversationId),
      model: requestedModel,
      provider: requestedProvider,
      ...whenDefined("idempotency", opts.runIdempotency),
    });
    if (started.ok) {
      return ndjsonResponse(async (send) => {
        for await (const event of streamStartedHermesRun({
          fetch,
          base,
          token,
          signal,
          run: started.run,
          ...whenDefined("conversationId", opts.conversationId),
        })) {
          send(event);
        }
      });
    }
    if (!started.unsupported) {
      return ndjsonResponse(
        async (send) => {
          send({ type: "error", message: started.message } satisfies ChatEvent);
        },
        started.status >= 400 ? started.status : 502,
      );
    }
  }

  const post = (model: string, provider: string) =>
    fetch(`${base}/v1/chat/completions`, {
      method: "POST",
      headers: hermesHeaders(token, {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
        ...(opts.conversationId
          ? { "X-Hermes-Session-Key": opts.conversationId.slice(0, 256) }
          : {}),
      }),
      signal,
      cache: "no-store",
      redirect: "manual",
      body: JSON.stringify({
        model,
        stream: true,
        messages: opts.messages,
        ...(provider ? { provider } : {}),
      }),
    });

  const first = await post(requestedModel, requestedProvider);
  const resolved = await resolveChatModelFallback({
    requestedModel,
    requestedProvider,
    response: first,
    post,
  });
  const upstream = resolved.response;

  if (upstream.status === 401 || upstream.status === 403) {
    return ndjsonResponse(async (send) => {
      send({ type: "error", message: "The key is not correct." });
    }, 401);
  }
  if (!upstream.ok || !upstream.body) {
    const detail = hermesDetail(await hermesJson(upstream), FAIL);
    const limit = classifyModelLimit({
      status: upstream.status,
      message: detail,
      retryAfter: upstream.headers.get("retry-after"),
    });
    return ndjsonResponse(
      async (send) => {
        send({
          type: "error",
          message: detail,
          ...(limit ? { limit } : {}),
        } satisfies ChatEvent);
      },
      upstream.status >= 400 ? upstream.status : 502,
    );
  }

  return ndjsonResponse(async (send) => {
    if (resolved.notice) {
      send({ type: "model-fallback", ...resolved.notice } satisfies ChatEvent);
    }
    let emitted = 0;
    for await (const chunk of readSse(upstream.body!)) {
      const ev = eventFromChunk(chunk);
      if (!ev) continue;
      send(ev);
      emitted += 1;
      if (ev.type === "error") return;
    }
    if (emitted === 0) {
      send({
        type: "error",
        message: "Hermes sent no text. Try again or switch models.",
      });
    }
  });
}
