import { describe, expect, it } from "vitest";
import { appendReleaseHeaders, releaseMetadata } from "./release.server";

describe("release metadata", () => {
  it("uses a bounded commit fingerprint in Vercel production", () => {
    expect(
      releaseMetadata({
        VERCEL: "1",
        VERCEL_ENV: "production",
        VERCEL_GIT_COMMIT_SHA: "1234567890abcdef",
      }),
    ).toEqual({
      version: "1234567890ab",
      environment: "production",
      source: "vercel",
    });
  });

  it("rejects unsafe configured versions and fails closed to development", () => {
    expect(
      releaseMetadata({ ALICE_VERSION: "private value with spaces" }),
    ).toEqual({
      version: "development",
      environment: "development",
      source: "local",
    });
  });

  it("attaches only closed release headers", () => {
    const headers = new Headers();
    appendReleaseHeaders(headers, {
      version: "abc1234",
      environment: "preview",
      source: "vercel",
    });
    expect(Object.fromEntries(headers)).toEqual({
      "x-alice-environment": "preview",
      "x-alice-version": "abc1234",
    });
  });
});
