import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  asList,
  asRec,
  channelTestFromApi,
  channelsFromApi,
  cronDeliveryTargetsFromApi,
  cronFromApi,
  cronFromUnknown,
  curatorFromApi,
  diagnosticsFromApi,
  groupLabel,
  mcpFromApi,
  pluginsFromApi,
  pairingList,
  prettyName,
  projectFromUnknown,
  projectsFromApi,
  profilesFromApi,
  sessionsFromApi,
  sessionMessagesFromApi,
  skillHubResultsFromApi,
  skillsFromApi,
  str,
  toolsetsFromApi,
  toolsetDetailsFromApi,
  webhookCreationFromApi,
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
      skillHubResultsFromApi({
        results: [
          {
            identifier: "official/research/arxiv",
            name: "arxiv",
            description: "Search papers",
            source: "official",
            trust_level: "builtin",
            download_url: "must-not-reach-alice",
          },
        ],
      }),
    ).toEqual([
      {
        identifier: "official/research/arxiv",
        name: "arxiv",
        description: "Search papers",
        source: "official",
        trust: "builtin",
      },
    ]);
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
      toolsetDetailsFromApi(
        "web",
        {
          name: "web",
          active_search_backend: "brave",
          providers: [
            {
              name: "brave",
              badge: "Brave",
              is_active: true,
              status: "ready",
              capabilities: ["search", "unknown"],
              env_vars: [
                {
                  key: "BRAVE_API_KEY",
                  prompt: "API key",
                  is_set: true,
                  value: "must-not-leak",
                },
              ],
            },
          ],
        },
        {
          current: "search-v1",
          models: [{ id: "search-v1", display: "Search v1" }],
        },
      ),
    ).toMatchObject({
      activeSearchProvider: "brave",
      currentModel: "search-v1",
      providers: [
        {
          name: "brave",
          status: "ready",
          capabilities: ["search"],
          envVars: [{ key: "BRAVE_API_KEY", isSet: true }],
        },
      ],
    });
    expect(
      pluginsFromApi({
        plugins: [
          {
            name: "kanban",
            version: "1.2.0",
            description: "Boards",
            source: "git",
            runtime_status: "enabled",
            can_remove: true,
            can_update_git: true,
            auth_required: false,
            path: "/private/must-not-leak",
          },
        ],
      }),
    ).toEqual([
      {
        id: "plugin:kanban",
        name: "kanban",
        version: "1.2.0",
        description: "Boards",
        source: "git",
        enabled: true,
        status: "enabled",
        canRemove: true,
        canUpdate: true,
        authRequired: false,
        authCommand: undefined,
      },
    ]);
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
        platforms: [
          {
            id: "telegram",
            enabled: true,
            configured: true,
            gateway_running: true,
            env_vars: [
              {
                key: "TELEGRAM_BOT_TOKEN",
                required: true,
                is_set: true,
                redacted_value: "••••1234",
                value: "must-not-leak",
                is_password: true,
              },
            ],
          },
        ],
      })[0],
    ).toMatchObject({
      id: "telegram",
      state: "activo",
      gatewayRunning: true,
      envVars: [
        {
          key: "TELEGRAM_BOT_TOKEN",
          isSet: true,
          redactedValue: "••••1234",
          isPassword: true,
        },
      ],
    });
    expect(
      JSON.stringify(
        channelsFromApi({
          platforms: [
            {
              id: "telegram",
              env_vars: [{ key: "TELEGRAM_BOT_TOKEN", value: "must-not-leak" }],
            },
          ],
        }),
      ),
    ).not.toContain("must-not-leak");
    expect(
      channelTestFromApi({ ok: false, state: "disconnected", message: "No" }),
    ).toEqual({ ok: false, state: "disconnected", message: "No" });
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
        enabled: true,
        base_url: "http://localhost:8644",
        subscriptions: [
          {
            name: "deploy",
            events: ["push"],
            deliver: "telegram",
            secret_set: true,
            url: "http://localhost:8644/webhooks/deploy",
          },
        ],
      }),
    ).toEqual({
      enabled: true,
      baseUrl: "http://localhost:8644",
      subscriptions: [
        expect.objectContaining({
          name: "deploy",
          events: ["push"],
          deliver: "telegram",
          secretSet: true,
        }),
      ],
    });
    expect(
      projectFromUnknown({
        id: "project-1",
        name: "Alice",
        board_slug: "alice-board",
        active: true,
        archived: true,
        folders: [
          { path: "/workspace", label: "App", is_primary: true },
          { path: "/workspace/api", label: "API", is_primary: false },
        ],
      }),
    ).toMatchObject({
      id: "project-1",
      path: "/workspace",
      boardSlug: "alice-board",
      active: true,
      archived: true,
      folders: [
        { path: "/workspace", label: "App", primary: true },
        { path: "/workspace/api", label: "API", primary: false },
      ],
    });
    expect(projectsFromApi({ projects: [{ id: "project-1" }] })).toHaveLength(
      1,
    );
    expect(
      profilesFromApi({
        profiles: [
          {
            name: "research",
            display_name: "Research",
            description: "Evidence and synthesis",
            description_auto: false,
            model: "gpt-5.6",
            provider: "openai",
            skill_count: 7,
            has_env: true,
            gateway_running: true,
          },
          { name: "default", is_default: true },
        ],
      }),
    ).toEqual([
      expect.objectContaining({
        name: "default",
        displayName: "Default",
        isDefault: true,
        skillCount: 0,
      }),
      expect.objectContaining({
        name: "research",
        displayName: "Research",
        description: "Evidence and synthesis",
        isDefault: false,
        model: "gpt-5.6",
        provider: "openai",
        skillCount: 7,
        hasEnv: true,
        gatewayRunning: true,
      }),
    ]);
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

  it("exposes a webhook secret only from a valid one-time create response", () => {
    expect(
      webhookCreationFromApi({
        secret: "one-time-secret",
        url: "https://hermes.example/webhooks/push",
        bearer_token: "must-not-leak",
      }),
    ).toEqual({
      secret: "one-time-secret",
      url: "https://hermes.example/webhooks/push",
    });
    expect(
      webhookCreationFromApi({
        secret: "one-time-secret",
        url: "javascript:alert(1)",
      }),
    ).toBeNull();
    expect(
      webhookCreationFromApi({
        secret: "x".repeat(513),
        url: "https://hermes.example/webhooks/push",
      }),
    ).toBeNull();
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
