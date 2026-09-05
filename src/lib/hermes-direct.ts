export * from "./hermes-direct.legacy";

import {
  assertGatewayKey,
  eventFromChunk,
  normalizeGatewayUrl,
  readSse,
  scopeHermesGatewayBase,
  type ChatEvent,
  type HermesChatContent,
} from "./gateway";
import { classifyModelLimit } from "./model-limit";
import { resolveChatModelFallback } from "./model-fallback";
import { startHermesRun, streamStartedHermesRun } from "./hermes-run-transport";
import { whenDefined } from "./exact-optional";

const FAIL = "Couldn’t connect.";
const CORS_ERROR = "Hermes is online, but it hasn’t allowed Alice yet (CORS).";

function headers(token: string, extra?: Record<string, string>): HeadersInit {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    ...extra,
  };
}

async function directFailureDetail(response: Response): Promise<string> {
  try {
    const body = (await response.clone().json()) as Record<string, unknown>;
    const detail = body?.detail ?? body?.message ?? body?.error;
    if (typeof detail === "string" && detail.trim()) return detail.trim();
    if (detail && typeof detail === "object" && !Array.isArray(detail)) {
      const nested = detail as Record<string, unknown>;
      if (typeof nested.message === "string" && nested.message.trim()) {
        return nested.message.trim();
      }
    }
  } catch {
    // Non-JSON body: keep the stable fallback wording below.
  }
  return "";
}

/**
 * Direct-browser counterpart of the proxy chat transport. The fallback policy
 * is intentionally delegated to the same shared resolver as the proxy so a
 * device connection cannot silently behave differently from a proxied one.
 */
export async function* streamHermesDirect(opts: {
  url: string;
  key: string;
  messages: Array<{ role: "user" | "assistant"; content: HermesChatContent }>;
  conversationId?: string;
  model?: string;
  provider?: string;
  preferRuns?: boolean;
  runIdempotency?: boolean;
  signal: AbortSignal;
  profile?: string;
}): AsyncGenerator<ChatEvent> {
  const base = scopeHermesGatewayBase(
    normalizeGatewayUrl(opts.url),
    opts.profile,
  );
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  const requestedModel = opts.model?.trim() || "hermes-agent";
  const requestedProvider = opts.provider?.trim() || "";

  if (opts.preferRuns) {
    try {
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
        yield* streamStartedHermesRun({
          fetch,
          base,
          token,
          signal,
          run: started.run,
          ...whenDefined("conversationId", opts.conversationId),
        });
        return;
      }
      if (!started.unsupported) {
        yield { type: "error", message: started.message };
        return;
      }
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      yield { type: "error", message: CORS_ERROR };
      return;
    }
  }

  const post = (model: string, provider: string) =>
    fetch(`${base}/v1/chat/completions`, {
      method: "POST",
      headers: headers(token, {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
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

  let upstream: Response;
  let notice: Awaited<ReturnType<typeof resolveChatModelFallback>>["notice"];
  try {
    const first = await post(requestedModel, requestedProvider);
    const resolved = await resolveChatModelFallback({
      requestedModel,
      requestedProvider,
      response: first,
      post,
    });
    upstream = resolved.response;
    notice = resolved.notice;
  } catch (error) {
    if ((error as Error).name === "AbortError") return;
    yield { type: "error", message: CORS_ERROR };
    return;
  }

  if (upstream.status === 401 || upstream.status === 403) {
    yield { type: "error", message: "The key is not correct." };
    return;
  }
  if (!upstream.ok || !upstream.body) {
    const detail = await directFailureDetail(upstream);
    const limit = classifyModelLimit({
      status: upstream.status,
      message: detail,
      retryAfter: upstream.headers.get("retry-after"),
    });
    yield {
      type: "error",
      message: detail || FAIL,
      ...(limit ? { limit } : {}),
    };
    return;
  }

  if (notice) yield { type: "model-fallback", ...notice };

  let emitted = 0;
  for await (const chunk of readSse(upstream.body)) {
    const ev = eventFromChunk(chunk);
    if (!ev) continue;
    yield ev;
    emitted += 1;
    if (ev.type === "error") return;
  }
  if (emitted === 0) {
    yield {
      type: "error",
      message: "Hermes sent no text. Try again or switch models.",
    };
  }
}
