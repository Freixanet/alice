import { describe, expect, it } from "vitest";
import {
  boundedLatency,
  browserFamily,
  clientOperationalEventSchema,
  normalizeOperationalRoute,
  viewportBucket,
} from "./operational-telemetry";

describe("operational telemetry privacy contract", () => {
  it("normalizes routes without retaining paths, queries or fragments", () => {
    expect(normalizeOperationalRoute("/skills?query=secret#result")).toBe(
      "/skills",
    );
    expect(normalizeOperationalRoute("/conversation/private-id")).toBe("other");
    expect(normalizeOperationalRoute("")).toBe("/");
  });

  it("reduces user agents and viewport widths to coarse categories", () => {
    expect(
      browserFamily(
        "Mozilla/5.0 AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0",
      ),
    ).toBe("edge");
    expect(
      browserFamily("Mozilla/5.0 Version/18.0 Mobile/15E148 Safari/604.1"),
    ).toBe("safari");
    expect(browserFamily("custom-client/1.0")).toBe("other");
    expect([320, 390, 1024, 1440].map(viewportBucket)).toEqual([
      "compact",
      "narrow",
      "medium",
      "wide",
    ]);
  });

  it("rejects content, identifiers, raw URLs and arbitrary error messages", () => {
    const safe = {
      kind: "client_error",
      route: "/",
      browser: "safari",
      viewport: "narrow",
      code: "runtime_error",
    } as const;
    expect(clientOperationalEventSchema.safeParse(safe).success).toBe(true);
    for (const forbidden of [
      { userId: "user-1" },
      { message: "the prompt failed" },
      { url: "https://hermes.example" },
      { content: "private conversation" },
    ]) {
      expect(
        clientOperationalEventSchema.safeParse({ ...safe, ...forbidden })
          .success,
      ).toBe(false);
    }
  });

  it("bounds latency to a finite, non-identifying integer", () => {
    expect(boundedLatency(-1)).toBe(0);
    expect(boundedLatency(12.6)).toBe(13);
    expect(boundedLatency(Number.NaN)).toBe(0);
    expect(boundedLatency(999_999)).toBe(120_000);
  });
});
