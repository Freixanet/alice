import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  asList,
  asRec,
  channelsFromApi,
  cronDeliveryTargetsFromApi,
  cronFromApi,
  cronFromUnknown,
  curatorFromApi,
  diagnosticsFromApi,
  groupLabel,
  mcpFromApi,
  pairingList,
  prettyName,
  projectFromUnknown,
  projectsFromApi,
  sessionsFromApi,
  sessionMessagesFromApi,
  skillsFromApi,
  str,
  toolsetsFromApi,
  webhooksFromApi,
} from "./hermes-live-parse";

describe("Hermes cron contract parsing", () => {
  it("retains every editable field from Hermes 0.20.6", () => {
    expect(
      cronFromUnknown({
        id: "job-1",
        name: "Morning",
        prompt: "Summarize the day",
        schedule_display: "0 9 * * 1-5",
        deliver: "telegram",
        skills: ["research", "writing"],
        model: "gpt-5.6",
        provider: "openai",
        script: "prepare.py",
        workdir: "/workspace",
        enabled_toolsets: ["web"],
        no_agent: false,
      }),
    ).toMatchObject({
      id: "job-1",
      prompt: "Summarize the day",
      deliver: "telegram",
      skills: ["research", "writing"],
      model: "gpt-5.6",
      provider: "openai",
      script: "prepare.py",
      workdir: "/workspace",
      enabledToolsets: ["web"],
      noAgent: false,
    });
  });

  it("only offers configured delivery targets and always includes local", () => {
    expect(
      cronDeliveryTargetsFromApi({
        targets: [
          { id: "telegram", name: "Telegram", home_target_set: true },
          { id: "slack", name: "Slack", home_target_set: false },
        ],
      }),
    ).toEqual([
      { id: "local", name: "Local (save only)", homeTargetSet: true },
      { id: "telegram", name: "Telegram", homeTargetSet: true },
      { id: "slack", name: "Slack", homeTargetSet: false },
    ]);
  });

  it("normalizes every management collection exposed by supported Hermes", () => {
    expect(asRec(null)).toEqual({});
    expect(asList({ jobs: [{ id: "j" }] })).toHaveLength(1);
    expect(str("  value ")).toBe("value");
    expect(prettyName("google_chat")).toBe("Google Chat");
    expect(groupLabel("software-development")).toBe("Development");
    expect(
      skillsFromApi({
        skills: [
          {
            name: "research",
            description: "Search",
            category: "research",
            enabled: true,
          },
        ],
      }),
    ).toHaveLength(1);
    expect(
      toolsetsFromApi({
        toolsets: [
          {
            name: "web",
            tools: ["web_search"],
            enabled: true,
            configured: true,
          },
        ],
      })[0],
    ).toMatchObject({ id: "web", tools: ["web_search"], enabled: true });
    expect(
      mcpFromApi({
        servers: [{ name: "docs", url: "https://example.com", enabled: true }],
      })[0],
    ).toMatchObject({ id: "docs", transport: "http" });
    expect(
      cronFromApi({ jobs: [{ id: "j", schedule_display: "every 1h" }] }),
    ).toHaveLength(1);
    expect(
      channelsFromApi({
        platforms: [{ id: "telegram", enabled: true, configured: true }],
      })[0],
    ).toMatchObject({ id: "telegram", state: "activo" });
    expect(
      sessionsFromApi({
        sessions: [
          {
            session_id: "session-1",
            preview: "Hello",
            updated_at: 1_700_000_000,
            messages: 2,
            pinned: true,
            unread: 1,
          },
        ],
      })[0],
    ).toMatchObject({
      id: "session-1",
      title: "Hello",
      messages: 2,
      pinned: true,
      archived: false,
      unread: true,
    });
    expect(
      pairingList([
        { platform: "telegram", request_id: "request", user_name: "Alice" },
      ])[0],
    ).toEqual({
      platform: "telegram",
      code: undefined,
      requestId: "request",
      userId: undefined,
      user: "Alice",
    });
    expect(
      webhooksFromApi({
        subscriptions: [{ name: "deploy", events: ["push"] }],
      })[0],
    ).toMatchObject({ name: "deploy", event: "push" });
    expect(
      projectFromUnknown({
        id: "project-1",
        name: "Alice",
        folders: [{ path: "/workspace", is_primary: true }],
      }),
    ).toMatchObject({ id: "project-1", path: "/workspace" });
    expect(projectsFromApi({ projects: [{ id: "project-1" }] })).toHaveLength(
      1,
    );
    expect(
      curatorFromApi({
        enabled: true,
        paused: false,
        interval_hours: 6,
        last_run_at: 1_700_000_000,
        min_idle_hours: 2,
        stale_after_days: 30,
        archive_after_days: 90,
      }),
    ).toEqual({
      enabled: true,
      paused: false,
      intervalHours: 6,
      lastRunAt: "2023-11-14T22:13:20.000Z",
      minIdleHours: 2,
      staleAfterDays: 30,
      archiveAfterDays: 90,
    });
    expect(curatorFromApi({ enabled: "yes", paused: false })).toBeNull();
  });

  it("is total for arbitrary Hermes responses", () => {
    fc.assert(
      fc.property(fc.jsonValue(), (value) => {
        expect(() => cronFromUnknown(value)).not.toThrow();
        expect(() => cronDeliveryTargetsFromApi(value)).not.toThrow();
        expect(() => curatorFromApi(value)).not.toThrow();
      }),
      { numRuns: 10_000 },
    );
  }, 15_000);

  it("bounds and normalizes official session messages as inert text", () => {
    const messages = sessionMessagesFromApi({
      data: [
        {
          id: "one",
          role: "assistant",
          content: "Hello",
          timestamp: 1_700_000_000,
        },
        {
          id: "two",
          role: "tool",
          tool_name: "web_search",
          content: { result: "safe" },
        },
      ],
    });
    expect(messages).toEqual([
      {
        id: "one",
        role: "assistant",
        content: "Hello",
        timestamp: "2023-11-14T22:13:20.000Z",
        toolName: undefined,
      },
      {
        id: "two",
        role: "tool",
        content: '{"result":"safe"}',
        timestamp: undefined,
        toolName: "web_search",
      },
    ]);
    const bounded = sessionMessagesFromApi({
      data: Array.from({ length: 80 }, (_, index) => ({
        role: "assistant",
        content: "x".repeat(5_000),
        id: String(index),
      })),
    });
    expect(bounded).toHaveLength(50);
    expect(bounded.every((row) => row.content.length <= 4_000)).toBe(true);
  });

  it("projects detailed health into a bounded, secret-free diagnostic view", () => {
    const diagnostics = diagnosticsFromApi({
      status: "ready",
      version: "0.20.6",
      gateway_state: "running",
      active_agents: 2,
      gateway_busy: true,
      gateway_drainable: false,
      updated_at: 1_700_000_000,
      exit_reason: "",
      platforms: {
        telegram: { status: "connected", token: "must-not-leak" },
        slack: false,
      },
      api_key: "must-not-leak",
      pid: 1234,
    });
    expect(diagnostics).toEqual({
      status: "ready",
      version: "0.20.6",
      gatewayState: "running",
      activeAgents: 2,
      busy: true,
      drainable: false,
      updatedAt: "2023-11-14T22:13:20.000Z",
      exitReason: undefined,
      platforms: [
        { id: "telegram", name: "Telegram", status: "connected" },
        { id: "slack", name: "Slack", status: "disconnected" },
      ],
    });
    expect(JSON.stringify(diagnostics)).not.toContain("must-not-leak");
    expect(
      diagnosticsFromApi({
        platforms: Object.fromEntries(
          Array.from({ length: 50 }, (_, index) => [
            `p-${index}`,
            "x".repeat(500),
          ]),
        ),
      }).platforms,
    ).toHaveLength(32);
  });
});
