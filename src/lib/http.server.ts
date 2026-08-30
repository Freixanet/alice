import type { z } from "zod";

export type RequestErrorCode =
  | "invalid_content_type"
  | "invalid_json"
  | "invalid_request"
  | "request_too_large"
  | "cross_site_request";

export class RequestContractError extends Error {
  constructor(
    readonly code: RequestErrorCode,
    readonly status: 400 | 403 | 413 | 415,
  ) {
    super(code);
    this.name = "RequestContractError";
  }
}

export async function parseJsonRequest<T extends z.ZodType>(
  request: Request,
  schema: T,
  maxBytes: number,
): Promise<z.infer<T>> {
  assertSameOriginRequest(request);
  const contentType = request.headers.get("content-type")?.split(";", 1)[0];
  if (contentType !== "application/json") {
    throw new RequestContractError("invalid_content_type", 415);
  }
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new RequestContractError("request_too_large", 413);
  }
  const text = await readTextWithinLimit(request, maxBytes);
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new RequestContractError("invalid_json", 400);
  }
  const parsed = schema.safeParse(value);
  if (!parsed.success) {
    throw new RequestContractError("invalid_request", 400);
  }
  return parsed.data;
}

export function requestErrorResponse(error: unknown): Response | null {
  if (!(error instanceof RequestContractError)) return null;
  return Response.json(
    { ok: false, error: { code: error.code } },
    {
      status: error.status,
      headers: { "Cache-Control": "no-store" },
    },
  );
}

export function assertSameOriginRequest(request: Request): void {
  const fetchSite = request.headers.get("sec-fetch-site");
  if (fetchSite && fetchSite !== "same-origin" && fetchSite !== "none") {
    throw new RequestContractError("cross_site_request", 403);
  }
  const origin = request.headers.get("origin");
  if (!origin) return;
  let expected: string;
  try {
    expected = new URL(request.url).origin;
  } catch {
    throw new RequestContractError("cross_site_request", 403);
  }
  if (origin !== expected) {
    throw new RequestContractError("cross_site_request", 403);
  }
}

async function readTextWithinLimit(
  request: Request,
  maxBytes: number,
): Promise<string> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let bytes = 0;
  let text = "";
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      bytes += chunk.value.byteLength;
      if (bytes > maxBytes) {
        await reader.cancel("request_too_large");
        throw new RequestContractError("request_too_large", 413);
      }
      text += decoder.decode(chunk.value, { stream: true });
    }
    text += decoder.decode();
    return text;
  } catch (error) {
    if (error instanceof RequestContractError) throw error;
    throw new RequestContractError("invalid_json", 400);
  } finally {
    reader.releaseLock();
  }
}
