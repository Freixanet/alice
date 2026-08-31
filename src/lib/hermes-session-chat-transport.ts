import { readSse, type ChatEvent, type HermesChatContent } from "./gateway";
import { eventsFromHermesRunChunk } from "./hermes-runs";

type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

export async function* streamHermesSessionChat(opts: {
  fetch: FetchLike;
  base: string;
  token: string;
  sessionId: string;
  message: HermesChatContent;
  conversationId?: string;
  model?: string;
  provider?: string;
  signal: AbortSignal;
}): AsyncGenerator<ChatEvent> {
  const response = await opts.fetch(
    `${opts.base}/api/sessions/${encodeURIComponent(opts.sessionId)}/chat/stream`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${opts.token}`,
        "X-Hermes-Session-Token": opts.token,
        Accept: "text/event-stream",
        "Content-Type": "application/json",
        ...(opts.conversationId
          ? { "X-Hermes-Session-Key": opts.conversationId.slice(0, 128) }
          : {}),
      },
      body: JSON.stringify({
        message: opts.message,
        ...(opts.model?.trim() ? { model: opts.model.trim() } : {}),
        ...(opts.provider?.trim() ? { provider: opts.provider.trim() } : {}),
      }),
      signal: opts.signal,
      cache: "no-store",
      redirect: "manual",
    },
  );

  if (!response.ok || !response.body) {
    yield { type: "error", message: await responseError(response) };
    return;
  }

  let emitted = 0;
  let emittedDelta = false;
  for await (const chunk of readSse(response.body)) {
    for (const event of eventsFromHermesRunChunk(chunk)) {
      if (event.type === "delta") emittedDelta = true;
      emitted += 1;
      yield event;
      if (event.type === "error") return;
    }
    if (emittedDelta) continue;
    const completed = assistantCompletedContent(chunk);
    if (completed) {
      emittedDelta = true;
      emitted += 1;
      yield { type: "delta", text: completed };
    }
  }

  if (emitted === 0) {
    yield {
      type: "error",
      message: "Hermes sent no text. Try again or switch models.",
    };
  }
}

function assistantCompletedContent(chunk: string): string | null {
  try {
    const value = JSON.parse(chunk) as Record<string, unknown>;
    return value.type === "assistant.completed" &&
      typeof value.content === "string" &&
      value.content
      ? value.content.slice(0, 1_000_000)
      : null;
  } catch {
    return null;
  }
}

async function responseError(response: Response): Promise<string> {
  try {
    const value = (await response.json()) as Record<string, unknown>;
    const nested =
      value.error &&
      typeof value.error === "object" &&
      !Array.isArray(value.error)
        ? (value.error as Record<string, unknown>)
        : null;
    const message =
      (typeof nested?.message === "string" && nested.message) ||
      (typeof value.error === "string" && value.error) ||
      (typeof value.message === "string" && value.message);
    if (message) return message.slice(0, 8_000);
  } catch {
    // The upstream may return an empty or non-JSON failure response.
  }
  return "Couldn’t connect.";
}
