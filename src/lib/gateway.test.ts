import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  assertGatewayKey,
  isPrivateHostname,
  normalizeGatewayUrl,
  normalizeLlmBaseUrl,
  parseHermesModelOptions,
} from "./gateway";

describe("gateway input invariants", () => {
  it.each([
    ["example.com", "https://example.com"],
    ["https://example.com/", "https://example.com"],
    ["http://127.0.0.1:8642/", "http://127.0.0.1:8642"],
  ])("normalizes %s", (input, expected) => {
    expect(normalizeGatewayUrl(input)).toBe(expected);
  });

  it("rejects credentials, paths and unsupported protocols", () => {
    for (const input of [
      "ftp://example.com",
      "https://user:pass@example.com",
    ]) {
      expect(() => normalizeGatewayUrl(input)).toThrow();
    }
  });

  it("accepts OpenAI base paths and removes duplicate suffixes", () => {
    expect(normalizeLlmBaseUrl("https://api.example.com/v1/")).toBe(
      "https://api.example.com/v1",
    );
  });

  it("never accepts control characters in a gateway key", () => {
    fc.assert(
      fc.property(fc.string(), (value) => {
        const clean = [...value.trim()].every((char) => {
          const code = char.charCodeAt(0);
          return code > 31 && code !== 127;
        });
        if (clean && value.trim().length >= 8 && value.trim().length <= 256)
          return;
        expect(() => assertGatewayKey(value)).toThrow();
      }),
      { numRuns: 10_000 },
    );
  });

  it.each(["localhost", "127.0.0.1", "::1", "10.0.0.2", "192.168.1.4"])(
    "classifies %s as private",
    (host) => expect(isPrivateHostname(host)).toBe(true),
  );
});

describe("Hermes model parsing", () => {
  it("deduplicates malformed model payloads without throwing", () => {
    const result = parseHermesModelOptions({
      current_model: "m1",
      data: [
        { id: "m1", provider: "nous" },
        { id: "m1", provider: "nous" },
        null,
        { id: "" },
      ],
    });
    expect(result.currentModel).toBe("m1");
    expect(result.models).toHaveLength(1);
  });

  it("is total for arbitrary JSON values", () => {
    fc.assert(
      fc.property(fc.jsonValue(), (value) => {
        expect(() => parseHermesModelOptions(value)).not.toThrow();
      }),
      { numRuns: 10_000 },
    );
  });
});
