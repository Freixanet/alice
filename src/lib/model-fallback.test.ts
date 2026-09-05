import { describe, expect, it, vi } from "vitest";
import {
  isModelCompatibilityFailure,
  resolveChatModelFallback,
} from "./model-fallback";

function response(status: number, body: unknown, headers?: HeadersInit) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

describe("model fallback classification", () => {
  it.each([
    [400, { detail: "Unknown model gpt-made-up" }],
    [404, { error: { message: "model_not_found" } }],
    [422, { detail: "Provider x does not support model y" }],
    [400, { detail: "No provider available for model y" }],
    [404, { detail: "Unknown provider selected" }],
  ])("allows identified incompatibility (%s)", (status, body) => {
    expect(
      isModelCompatibilityFailure({
        status,
        message: JSON.stringify(body),
      }),
    ).toBe(true);
  });

  it.each([
    [401, "Unknown model because credentials are invalid"],
    [403, "provider unavailable for this account"],
    [429, "usage_limit_reached for model gpt-5"],
    [429, "rate limit exceeded for provider openai"],
    [500, "unknown model"],
    [503, "provider unavailable"],
    [400, "invalid request body"],
    [404, "route not found"],
    [400, "invalid provider credentials for model gpt-5"],
    [422, "provider temporarily unavailable for model gpt-5"],
    [404, "model unavailable because upstream connection timed out"],
    [404, "provider unavailable"],
    [404, "model unavailable for this account"],
    [422, "provider unavailable for subscription plan"],
  ])("never falls back for unrelated failure (%s)", (status, message) => {
    expect(isModelCompatibilityFailure({ status, message })).toBe(false);
  });
});

describe("model fallback transport policy", () => {
  it("retries exactly once with Hermes Agent for an incompatible explicit model", async () => {
    const post = vi.fn(async () => response(200, { ok: true }));
    const first = response(400, { detail: "Unsupported model selected" });

    const result = await resolveChatModelFallback({
      requestedModel: "gpt-selected",
      requestedProvider: "openai",
      response: first,
      post,
    });

    expect(post).toHaveBeenCalledTimes(1);
    expect(post).toHaveBeenCalledWith("hermes-agent", "");
    expect(result.response.status).toBe(200);
    expect(result.notice).toEqual({
      requestedModel: "gpt-selected",
      requestedProvider: "openai",
      model: "hermes-agent",
      reason: "incompatible",
    });
  });

  it.each([
    [401, { detail: "unauthorized" }],
    [429, { error: { type: "insufficient_quota" } }],
    [503, { detail: "provider overloaded" }],
  ])("does not issue a second request for status %s", async (status, body) => {
    const post = vi.fn(async () => response(200, { ok: true }));
    const first = response(status, body);

    const result = await resolveChatModelFallback({
      requestedModel: "gpt-selected",
      requestedProvider: "openai",
      response: first,
      post,
    });

    expect(post).not.toHaveBeenCalled();
    expect(result.response).toBe(first);
    expect(result.notice).toBeUndefined();
  });

  it("keeps the original incompatibility if the allowed fallback also fails", async () => {
    const post = vi.fn(async () => response(503, { detail: "overloaded" }));
    const first = response(404, { detail: "Model not found" });

    const result = await resolveChatModelFallback({
      requestedModel: "missing-model",
      requestedProvider: "",
      response: first,
      post,
    });

    expect(post).toHaveBeenCalledTimes(1);
    expect(result.response).toBe(first);
    expect(result.notice).toBeUndefined();
  });
});
