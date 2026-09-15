import { describe, expect, it } from "vitest";
import { assertProductionConfiguration } from "./deployment-config";

const production = {
  NODE_ENV: "production",
  BETTER_AUTH_SECRET: "test-fixture-secret-with-32-characters",
  DATABASE_URL: "postgresql://test.invalid/alice",
};

describe("production configuration", () => {
  it("permits local development and a configured deployment", () => {
    expect(() =>
      assertProductionConfiguration({ NODE_ENV: "development" }),
    ).not.toThrow();
    expect(() => assertProductionConfiguration(production)).not.toThrow();
  });
  it.each([undefined, "", "   ", "short"])(
    "refuses unstable or weak session signing (%s)",
    (secret) => {
      expect(() =>
        assertProductionConfiguration({
          ...production,
          BETTER_AUTH_SECRET: secret,
        }),
      ).toThrow("BETTER_AUTH_SECRET");
    },
  );
  it("refuses ephemeral production data and shared anonymous accounts", () => {
    expect(() =>
      assertProductionConfiguration({ ...production, DATABASE_URL: " " }),
    ).toThrow("DATABASE_URL");
    expect(() =>
      assertProductionConfiguration({
        ...production,
        VITE_AUTH_ENABLED: "false",
      }),
    ).toThrow("authentication");
  });
  it("also protects serverless deployments without NODE_ENV", () => {
    expect(() => assertProductionConfiguration({ VERCEL: "1" })).toThrow(
      "BETTER_AUTH_SECRET",
    );
  });
});
