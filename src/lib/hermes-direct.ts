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
import { isHermesSelfUpdateIntent } from "./hermes-update-intent";
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

async function* streamHermesSelfUpdateDirect(opts: {
  base: string;
  token: string;
  signal: AbortSignal;
}): AsyncGenerator<ChatEvent> {
  const requestHeaders = headers(opts.token, {
    "Content-Type": "application/json",
  });

  try {
    const check = await fetch(
      `${opts.base}/api/hermes/update/check?force=true`,
      {
        headers: requestHeaders,
        signal: opts.signal,
        cache: "no-store",
        redirect: "manual",
      },
    );
    if (check.ok) {
      const body = (await check.json()) as Record<string, unknown>;
      if (body.can_apply === false) {
        const message =
          typeof body.message === "string" && body.message.trim()
            ? body.message.trim()
            : "Esta instalación de Hermes no admite actualizaciones desde Alice.";
        yield { type: "delta", text: message };
        return;
      }
      if (body.update_available === false && body.behind === 0) {
        yield { type: "delta", text: "Hermes ya está actualizado." };
        return;
      }
    }
  } catch (error) {
    if ((error as Error).name === "AbortError") return;
    // The apply endpoint performs its own admission checks, so a failed preview
    // should not block an explicitly requested update.
  }

  try {
    const response = await fetch(`${opts.base}/api/hermes/update`, {
      method: "POST",
      headers: requestHeaders,
      signal: opts.signal,
      cache: "no-store",
      redirect: "manual",
    });
    if (!response.ok) {
      yield {
        type: "error",
        message:
          (await directFailureDetail(response)) ||
          "No pude iniciar la actualización de Hermes.",
      };
      return;
    }
    const body = (await response.json()) as Record<string, unknown>;
    if (body.ok !== true) {
      const message = body.message ?? body.error;
      yield {
        type: "error",
        message:
          typeof message === "string" && message.trim()
            ? message.trim()
            : "Hermes rechazó la actualización.",
      };
      return;
    }
    yield {
      type: "delta",
      text:
        body.already_running === true
          ? "La actualización de Hermes ya estaba en curso. Se está ejecutando en segundo plano."
          : "Actualización de Hermes iniciada en segundo plano. No tienes que mantener este turno abierto; Hermes reiniciará los gateways al terminar y Alice puede desconectarse unos segundos durante el reinicio.",
    };
  } catch (error) {
    if ((error as Error).name === "AbortError") return;
    yield { type: "error", message: CORS_ERROR };
  }
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
  const managementBase = normalizeGatewayUrl(opts.url);
  const base = scopeHermesGatewayBase(managementBase, opts.profile);
  const token = assertGatewayKey(opts.key);
  const signal = AbortSignal.any([opts.signal, AbortSignal.timeout(180_000)]);
  const requestedModel = opts.model?.trim() || "hermes-agent";
  const requestedProvider = opts.provider?.trim() || "";
  const latestUser = [...opts.messages]
    .reverse()
    .find((message) => message.role === "user");

  if (
    latestUser &&
    typeof latestUser.content === "string" &&
    isHermesSelfUpdateIntent(latestUser.content)
  ) {
    yield* streamHermesSelfUpdateDirect({
      base: managementBase,
      token,
      signal,
    });
    return;
  }

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
