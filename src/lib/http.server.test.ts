import { describe, expect, it } from "vitest";
import { z } from "zod";
import { parseJsonRequest } from "./http.server";

const schema = z.strictObject({ value: z.string().max(8) });

function request(body: string, headers: HeadersInit = {}) {
  return new Request("https://alice.example/api/test", {
    method: "POST",
    body,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

describe("parseJsonRequest", () => {
  it("returns schema-validated JSON", async () => {
    await expect(
      parseJsonRequest(request('{"value":"alice"}'), schema, 128),
    ).resolves.toEqual({ value: "alice" });
  });

  it("rejects cross-origin requests", async () => {
    await expect(
      parseJsonRequest(
        request('{"value":"alice"}', {
          Origin: "https://attacker.example",
        }),
        schema,
        128,
      ),
    ).rejects.toMatchObject({
      code: "cross_site_request",
      status: 403,
    });
  });

  it("rejects same-site sibling origins using Fetch Metadata", async () => {
    await expect(
      parseJsonRequest(
        request('{"value":"alice"}', {
          "Sec-Fetch-Site": "same-site",
        }),
        schema,
        128,
      ),
    ).rejects.toMatchObject({
      code: "cross_site_request",
      status: 403,
    });
  });

  it("enforces the actual byte limit", async () => {
    await expect(
      parseJsonRequest(request('{"value":"alice"}'), schema, 4),
    ).rejects.toMatchObject({
      code: "request_too_large",
      status: 413,
    });
  });

  it("counts UTF-8 bytes while streaming a chunked body", async () => {
    const encoder = new TextEncoder();
    const body = new ReadableStream({
      start(controller) {
        controller.enqueue(encoder.encode('{"value":"'));
        controller.enqueue(encoder.encode("álice"));
        controller.enqueue(encoder.encode('"}'));
        controller.close();
      },
    });
    const streamed = new Request("https://alice.example/api/test", {
      method: "POST",
      body,
      duplex: "half",
      headers: { "Content-Type": "application/json" },
    } as RequestInit & { duplex: "half" });
    await expect(parseJsonRequest(streamed, schema, 16)).rejects.toMatchObject({
      code: "request_too_large",
      status: 413,
    });
  });
});
