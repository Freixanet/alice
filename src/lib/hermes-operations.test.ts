import { describe, expect, it } from "vitest";
import { hermesMutationSchema, hermesOperationFor } from "./hermes-operations";

describe("official Hermes management operations", () => {
  it("maps the complete cron lifecycle to Hermes 0.20.6 routes", () => {
    expect(
      hermesOperationFor({ action: "cron-run", jobId: "daily/brief" }),
    ).toEqual({
      path: "/api/cron/jobs/daily%2Fbrief/trigger",
      method: "POST",
    });
    expect(
      hermesOperationFor({
        action: "cron-update",
        jobId: "one",
        updates: { model: "gpt-5.6", enabledToolsets: ["web"] },
      }),
    ).toMatchObject({
      path: "/api/cron/jobs/one",
      method: "PUT",
      body: { updates: { model: "gpt-5.6", enabled_toolsets: ["web"] } },
    });
    expect(
      hermesMutationSchema.safeParse({
        action: "cron-delete",
        jobId: "one",
      }).success,
    ).toBe(false);
  });

  it("uses official skill and MCP routes and never invents a project API", () => {
    expect(
      hermesOperationFor({
        action: "skill-install",
        identifier: "github:org/skill",
      }),
    ).toEqual({
      path: "/api/skills/hub/install",
      method: "POST",
      body: { identifier: "github:org/skill" },
    });
    expect(
      hermesOperationFor({ action: "mcp-test", name: "my server" }),
    ).toEqual({
      path: "/api/mcp/servers/my%20server/test",
      method: "POST",
    });
    expect(
      hermesOperationFor({
        action: "project-create",
        name: "Alice",
        path: "/workspace/alice",
      }),
    ).toBeNull();
  });

  it("requires contextual confirmation for destructive operations", () => {
    for (const value of [
      { action: "cron-delete", jobId: "one" },
      { action: "skill-uninstall", name: "one" },
      { action: "mcp-delete", name: "one" },
      { action: "session-delete", sessionId: "one" },
    ]) {
      expect(hermesMutationSchema.safeParse(value).success).toBe(false);
      expect(
        hermesMutationSchema.safeParse({ ...value, confirm: true }).success,
      ).toBe(true);
    }
  });
});
