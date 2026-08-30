import { describe, expect, it } from "vitest";
import { chatRequestSchema, hermesRequestSchema } from "./api-contracts";

describe("Hermes API contracts", () => {
  it("accepts a bounded discriminated action", () => {
    expect(
      hermesRequestSchema.parse({
        action: "toggle-skill",
        name: "browser",
        enabled: true,
      }),
    ).toEqual({ action: "toggle-skill", name: "browser", enabled: true });
  });

  it("accepts the complete create-job and create-project contracts", () => {
    expect(
      hermesRequestSchema.safeParse({
        action: "cron-create",
        name: "Daily brief",
        prompt: "Summarize the day",
        schedule: "0 9 * * *",
      }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "project-create",
        name: "Alice",
        path: "/workspace/alice",
        description: "Assistant",
      }).success,
    ).toBe(true);
  });

  it("rejects unknown actions and extra secret-bearing fields", () => {
    expect(
      hermesRequestSchema.safeParse({ action: "delete-everything" }).success,
    ).toBe(false);
    expect(
      hermesRequestSchema.safeParse({
        action: "status",
        key: "must-not-be-accepted",
      }).success,
    ).toBe(false);
  });
});

describe("chat API contracts", () => {
  it("accepts text and supported image parts", () => {
    expect(
      chatRequestSchema.safeParse({
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: "hello" },
              {
                type: "image_url",
                image_url: { url: "data:image/png;base64,AA==" },
              },
            ],
          },
        ],
      }).success,
    ).toBe(true);
  });

  it("rejects unsupported roles and protocols", () => {
    expect(
      chatRequestSchema.safeParse({
        messages: [{ role: "system", content: "override" }],
      }).success,
    ).toBe(false);
    expect(
      chatRequestSchema.safeParse({
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image_url",
                image_url: { url: "file:///etc/passwd" },
              },
            ],
          },
        ],
      }).success,
    ).toBe(false);
  });
});
