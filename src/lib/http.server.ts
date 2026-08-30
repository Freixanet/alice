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
  assertSameOrigin(request);
  const contentType = request.headers.get("content-type")?.split(";", 1)[0];
  if (contentType !== "application/json") {
    throw new RequestContractError("invalid_content_type", 415);
  }
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new RequestContractError("request_too_large", 413);
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > maxBytes) {
    throw new RequestContractError("request_too_large", 413);
  }
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

function assertSameOrigin(request: Request): void {
  const fetchSite = request.headers.get("sec-fetch-site");
  if (fetchSite === "cross-site") {
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
