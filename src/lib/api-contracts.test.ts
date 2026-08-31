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

  it("accepts explicitly scoped profile reads and mutations", () => {
    expect(
      hermesRequestSchema.safeParse({ action: "live", profile: "research" })
        .success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "profile-soul",
        name: "research",
      }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "mutate",
        profile: "research",
        mutation: { action: "toggle-skill", name: "browser", enabled: true },
      }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "live",
        profile: "../default",
      }).success,
    ).toBe(false);
  });

  it("accepts scoped run recovery and approval actions", () => {
    expect(
      hermesRequestSchema.safeParse({
        action: "run-status",
        runId: "run-1",
        conversationId: "chat-1",
      }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "run-approval",
        runId: "run-1",
        choice: "once",
      }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "run-approval",
        runId: "run-1",
        choice: "execute_anyway",
      }).success,
    ).toBe(false);
    expect(
      hermesRequestSchema.safeParse({
        action: "run-steer",
        runId: "run-1",
        input: "Focus on the failing test",
      }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "run-steer",
        runId: "run-1",
        input: "",
      }).success,
    ).toBe(false);
  });

  it("accepts only bounded session-message reads", () => {
    expect(
      hermesRequestSchema.safeParse({
        action: "session-messages",
        sessionId: "session-1",
      }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "session-messages",
        sessionId: "",
      }).success,
    ).toBe(false);
  });

  it("accepts the closed diagnostics action without extra fields", () => {
    expect(
      hermesRequestSchema.safeParse({ action: "diagnostics" }).success,
    ).toBe(true);
    expect(
      hermesRequestSchema.safeParse({
        action: "diagnostics",
        includeSecrets: true,
      }).success,
    ).toBe(false);
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
        preferRuns: true,
        hermesSessionId: "session-1",
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

  it("rejects empty, oversized, and unknown session chat fields", () => {
    const request = {
      messages: [{ role: "user", content: "hello" }],
    };
    expect(
      chatRequestSchema.safeParse({ ...request, hermesSessionId: "" }).success,
    ).toBe(false);
    expect(
      chatRequestSchema.safeParse({
        ...request,
        hermesSessionId: "s".repeat(161),
      }).success,
    ).toBe(false);
    expect(
      chatRequestSchema.safeParse({ ...request, session: "session-1" }).success,
    ).toBe(false);
  });
});
