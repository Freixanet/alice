import { classifyModelLimit } from "./model-limit";

export const HERMES_FALLBACK_MODEL = "hermes-agent";

export type ModelFallbackNotice = {
  requestedModel: string;
  requestedProvider?: string;
  model: string;
  provider?: string;
  reason: "incompatible";
};

export type ModelFallbackResolution = {
  response: Response;
  notice?: ModelFallbackNotice;
};

const COMPATIBILITY_STATUSES = new Set([400, 404, 422]);
const AUTH_CONTEXT =
  /\b(?:credential|credentials|api key|token|authentication|authenticate|unauthorized|forbidden|permission|billing)\b/i;
const TRANSIENT_CONTEXT =
  /\b(?:temporarily|temporary|timeout|timed out|overloaded|capacity|try again|service unavailable|connection|network|upstream|rate limit|too many requests)\b/i;

/**
 * Only errors that explicitly say the selected model/provider is incompatible
 * may change what the user asked for. Authentication, quota/rate limits,
 * outages and generic bad requests must reach the caller unchanged.
 */
export function isModelCompatibilityFailure(input: {
  status: number;
  message: string;
  retryAfter?: string | null;
}): boolean {
  if (!COMPATIBILITY_STATUSES.has(input.status)) return false;

  const limit = classifyModelLimit({
    status: input.status,
    message: input.message,
    retryAfter: input.retryAfter,
  });
  if (limit) return false;

  const normalized = input.message
    .toLowerCase()
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!normalized) return false;

  // Be conservative when an upstream incorrectly maps auth/transient failures
  // onto a 400/404/422. Those errors must never be converted into a provider
  // switch merely because their text also happens to mention a model.
  if (AUTH_CONTEXT.test(normalized) || TRANSIENT_CONTEXT.test(normalized)) {
    return false;
  }

  const subject = "(?:model|provider|model/provider|provider/model)";
  const incompatibility =
    "(?:not found|unknown|unsupported|not supported|unavailable|not available|does not exist|invalid)";

  return (
    new RegExp(`\\b${subject}\\b.{0,120}\\b${incompatibility}\\b`, "i").test(
      normalized,
    ) ||
    new RegExp(`\\b${incompatibility}\\b.{0,80}\\b${subject}\\b`, "i").test(
      normalized,
    ) ||
    /\bprovider\b.{0,80}\bdoes not support\b.{0,80}\bmodel\b/i.test(
      normalized,
    ) ||
    /\bno (?:available )?(?:endpoint|route|provider)s?\b.{0,100}\bmodel\b/i.test(
      normalized,
    )
  );
}

async function failureText(response: Response): Promise<string> {
  try {
    return (await response.clone().text()).slice(0, 32_000);
  } catch {
    return "";
  }
}

/**
 * Resolve the one allowed compatibility fallback for the OpenAI-compatible
 * chat transport. Both proxy and direct transports call this exact function
 * so their retry policy cannot drift apart.
 */
export async function resolveChatModelFallback(options: {
  requestedModel: string;
  requestedProvider: string;
  response: Response;
  post: (model: string, provider: string) => Promise<Response>;
}): Promise<ModelFallbackResolution> {
  const explicitSelection =
    options.requestedModel !== HERMES_FALLBACK_MODEL ||
    Boolean(options.requestedProvider);
  if (!explicitSelection || options.response.ok) {
    return { response: options.response };
  }

  const text = await failureText(options.response);
  if (
    !isModelCompatibilityFailure({
      status: options.response.status,
      message: text,
      retryAfter: options.response.headers.get("retry-after"),
    })
  ) {
    return { response: options.response };
  }

  let retry: Response;
  try {
    retry = await options.post(HERMES_FALLBACK_MODEL, "");
  } catch (error) {
    if ((error as Error).name === "AbortError") throw error;
    // A best-effort compatibility fallback must not replace the useful
    // original incompatibility error with an unrelated transport failure.
    return { response: options.response };
  }
  if (!retry.ok) return { response: options.response };

  return {
    response: retry,
    notice: {
      requestedModel: options.requestedModel,
      ...(options.requestedProvider
        ? { requestedProvider: options.requestedProvider }
        : {}),
      model: HERMES_FALLBACK_MODEL,
      reason: "incompatible",
    },
  };
}
