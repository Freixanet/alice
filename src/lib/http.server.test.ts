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

  it("enforces the actual byte limit", async () => {
    await expect(
      parseJsonRequest(request('{"value":"alice"}'), schema, 4),
    ).rejects.toMatchObject({
      code: "request_too_large",
      status: 413,
    });
  });
});
