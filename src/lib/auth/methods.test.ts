import { describe, expect, it } from "vitest";
import { configuredSignInMethods } from "./methods";

describe("available sign-in methods", () => {
  it("hides providers with incomplete credentials", () => {
    expect(
      configuredSignInMethods({
        GOOGLE_CLIENT_ID: "id",
        GOOGLE_CLIENT_SECRET: " ",
      }),
    ).toEqual([]);
    expect(
      configuredSignInMethods({ APPLE_CLIENT_ID: "id", APPLE_TEAM_ID: "team" }),
    ).toEqual([]);
  });
  it("exposes only names for configured native providers", () => {
    expect(
      configuredSignInMethods({
        GOOGLE_CLIENT_ID: "id",
        GOOGLE_CLIENT_SECRET: "private-value",
      }),
    ).toEqual(["google"]);
    expect(
      configuredSignInMethods({
        APPLE_CLIENT_ID: "id",
        APPLE_TEAM_ID: "team",
        APPLE_KEY_ID: "key",
        APPLE_PRIVATE_KEY: "private-value",
      }),
    ).toEqual(["apple"]);
  });
  it("does not offer the disabled broker on Vercel", () => {
    expect(
      configuredSignInMethods({
        VERCEL: "1",
        GROK_AUTH_CLIENT_ID: "id",
        GROK_AUTH_CLIENT_SECRET: "secret",
      }),
    ).toEqual([]);
  });
});
