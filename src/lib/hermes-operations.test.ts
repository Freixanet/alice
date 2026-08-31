import { describe, expect, it } from "vitest";
import {
  hermesMutationSchema,
  hermesOperationFor,
  hermesScopedOperationFor,
} from "./hermes-operations";

describe("official Hermes management operations", () => {
  it("scopes ordinary operations but never profile-management routes", () => {
    expect(
      hermesScopedOperationFor(
        { action: "toggle-skill", name: "browser", enabled: true },
        "research",
      )?.path,
    ).toBe("/api/skills/toggle?profile=research");
    expect(
      hermesScopedOperationFor(
        { action: "profile-activate", name: "research" },
        "default",
      )?.path,
    ).toBe("/api/profiles/active");
  });

  it("maps the supported profile lifecycle without exposing paths", () => {
    expect(
      hermesOperationFor({
        action: "profile-create",
        name: "research",
        cloneFrom: "default",
      }),
    ).toEqual({
      path: "/api/profiles",
      method: "POST",
      body: {
        name: "research",
        clone_from: "default",
        clone_all: undefined,
        no_skills: undefined,
        description: undefined,
      },
    });
    expect(
      hermesOperationFor({
        action: "profile-soul-update",
        name: "research",
        content: "Be rigorous.",
      }),
    ).toEqual({
      path: "/api/profiles/research/soul",
      method: "PUT",
      body: { content: "Be rigorous." },
    });
  });

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

  it("accepts one valid MCP transport and rejects unsafe environment names", () => {
    expect(
      hermesMutationSchema.safeParse({
        action: "mcp-create",
        name: "docs",
        url: "https://mcp.example.test",
        auth: "oauth",
      }).success,
    ).toBe(true);
    for (const value of [
      { action: "mcp-create", name: "docs" },
      {
        action: "mcp-create",
        name: "docs",
        url: "https://mcp.example.test",
        command: "npx",
      },
      { action: "mcp-create", name: "docs", url: "file:///tmp/server" },
      {
        action: "mcp-create",
        name: "docs",
        command: "npx",
        env: { "BAD-NAME": "secret" },
      },
    ]) {
      expect(hermesMutationSchema.safeParse(value).success).toBe(false);
    }
  });

  it("requires contextual confirmation for destructive operations", () => {
    for (const value of [
      { action: "cron-delete", jobId: "one" },
      { action: "skill-uninstall", name: "one" },
      { action: "mcp-delete", name: "one" },
      { action: "session-delete", sessionId: "one" },
      { action: "webhook-delete", name: "one" },
    ]) {
      expect(hermesMutationSchema.safeParse(value).success).toBe(false);
      expect(
        hermesMutationSchema.safeParse({ ...value, confirm: true }).success,
      ).toBe(true);
    }
  });

  it("keeps pairing request, code and user identifiers unambiguous", () => {
    expect(
      hermesOperationFor({
        action: "pairing-approve",
        platform: "telegram",
        requestId: "request-1",
      }),
    ).toEqual({
      path: "/api/pairing/approve",
      method: "POST",
      body: {
        platform: "telegram",
        request_id: "request-1",
        code: undefined,
      },
    });
    expect(
      hermesOperationFor({
        action: "pairing-revoke",
        platform: "telegram",
        userId: "user-1",
        confirm: true,
      }),
    ).toEqual({
      path: "/api/pairing/revoke",
      method: "POST",
      body: { platform: "telegram", user_id: "user-1" },
    });
  });

  it("maps the negotiated curator controls to the official admin routes", () => {
    expect(
      hermesOperationFor({ action: "curator-pause", paused: true }),
    ).toEqual({
      path: "/api/curator/paused",
      method: "PUT",
      body: { paused: true },
    });
    expect(hermesOperationFor({ action: "curator-run" })).toEqual({
      path: "/api/curator/run",
      method: "POST",
    });
  });

  it("maps safe channel configuration and tests to official routes", () => {
    expect(
      hermesOperationFor({
        action: "channel-update",
        platformId: "telegram",
        enabled: true,
        env: { TELEGRAM_BOT_TOKEN: "secret" },
        clearEnv: ["TELEGRAM_PROXY"],
      }),
    ).toEqual({
      path: "/api/messaging/platforms/telegram",
      method: "PUT",
      body: {
        enabled: true,
        env: { TELEGRAM_BOT_TOKEN: "secret" },
        clear_env: ["TELEGRAM_PROXY"],
      },
    });
    expect(
      hermesOperationFor({ action: "channel-test", platformId: "discord" }),
    ).toEqual({
      path: "/api/messaging/platforms/discord/test",
      method: "POST",
    });
    for (const value of [
      { action: "channel-update", platformId: "telegram" },
      {
        action: "channel-update",
        platformId: "telegram",
        env: { "BAD-NAME": "secret" },
      },
      {
        action: "channel-update",
        platformId: "telegram",
        env: { TOKEN: "secret" },
        clearEnv: ["TOKEN"],
      },
      { action: "channel-test", platformId: "bad/platform" },
    ]) {
      expect(hermesMutationSchema.safeParse(value).success).toBe(false);
    }
  });

  it("maps the complete webhook lifecycle to the official admin routes", () => {
    expect(hermesOperationFor({ action: "webhook-enable" })).toEqual({
      path: "/api/webhooks/enable",
      method: "POST",
    });
    expect(
      hermesOperationFor({
        action: "webhook-create",
        name: "github-push",
        description: "Repository pushes",
        events: ["push"],
        deliver: "telegram",
        deliverOnly: true,
        deliverChatId: "chat-1",
      }),
    ).toEqual({
      path: "/api/webhooks",
      method: "POST",
      body: {
        name: "github-push",
        description: "Repository pushes",
        events: ["push"],
        prompt: undefined,
        skills: undefined,
        deliver: "telegram",
        deliver_only: true,
        deliver_chat_id: "chat-1",
      },
    });
    expect(
      hermesOperationFor({
        action: "webhook-toggle",
        name: "github-push",
        enabled: false,
      }),
    ).toEqual({
      path: "/api/webhooks/github-push/enabled",
      method: "PUT",
      body: { enabled: false },
    });
    expect(
      hermesOperationFor({
        action: "webhook-delete",
        name: "github-push",
        confirm: true,
      }),
    ).toEqual({
      path: "/api/webhooks/github-push",
      method: "DELETE",
    });
  });

  it("rejects invalid webhook names and unsafe direct-delivery drafts", () => {
    for (const value of [
      { action: "webhook-create", name: "Uppercase" },
      { action: "webhook-create", name: "has spaces" },
      {
        action: "webhook-create",
        name: "alerts",
        deliver: "log",
        deliverOnly: true,
      },
      {
        action: "webhook-create",
        name: "alerts",
        events: Array.from({ length: 65 }, (_, index) => `event-${index}`),
      },
    ]) {
      expect(hermesMutationSchema.safeParse(value).success).toBe(false);
    }
  });

  it("maps negotiated session controls to their scoped official routes", () => {
    expect(
      hermesOperationFor({
        action: "session-create",
        sessionId: "alice-session",
        title: "Research",
        model: "gpt-5.6-luna",
        provider: "openai",
      }),
    ).toEqual({
      path: "/api/sessions",
      method: "POST",
      body: {
        id: "alice-session",
        title: "Research",
        source: "alice",
        model: "gpt-5.6-luna",
        provider: "openai",
        require_model_lock: true,
      },
    });
    expect(
      hermesOperationFor({
        action: "session-fork",
        sessionId: "mobile/chat",
        forkId: "alice-fork",
        title: "Alternative",
      }),
    ).toEqual({
      path: "/api/sessions/mobile%2Fchat/fork",
      method: "POST",
      body: { id: "alice-fork", title: "Alternative" },
    });
    expect(
      hermesOperationFor({
        action: "session-model-lock",
        sessionId: "one",
        model: "gpt-5.6-luna",
        provider: "openai",
      }),
    ).toEqual({
      path: "/api/sessions/one/model",
      method: "POST",
      body: {
        model: "gpt-5.6-luna",
        provider: "openai",
        require_model_lock: true,
      },
    });
    expect(
      hermesMutationSchema.safeParse({
        action: "session-model-lock",
        sessionId: "one",
        model: "",
      }).success,
    ).toBe(false);
    expect(
      hermesMutationSchema.safeParse({
        action: "session-create",
        sessionId: "alice-session",
        title: "   ",
      }).success,
    ).toBe(false);
  });

  it("rejects script-only jobs without an executable script", () => {
    expect(
      hermesMutationSchema.safeParse({
        action: "cron-create",
        name: "watchdog",
        prompt: "",
        schedule: "every 5m",
        noAgent: true,
      }).success,
    ).toBe(false);
    expect(
      hermesMutationSchema.safeParse({
        action: "cron-create",
        name: "watchdog",
        prompt: "",
        schedule: "every 5m",
        script: "memory-watchdog.sh",
        noAgent: true,
      }).success,
    ).toBe(true);
  });
});
