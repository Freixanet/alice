import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  asList,
  asRec,
  channelsFromApi,
  cronDeliveryTargetsFromApi,
  cronFromApi,
  cronFromUnknown,
  groupLabel,
  mcpFromApi,
  pairingList,
  prettyName,
  projectFromUnknown,
  projectsFromApi,
  sessionsFromApi,
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
          },
        ],
      })[0],
    ).toMatchObject({ id: "session-1", title: "Hello", messages: 2 });
    expect(
      pairingList([
        { platform: "telegram", request_id: "request", user_name: "Alice" },
      ])[0],
    ).toEqual({ platform: "telegram", code: "request", user: "Alice" });
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
  });

  it("is total for arbitrary Hermes responses", () => {
    fc.assert(
      fc.property(fc.jsonValue(), (value) => {
        expect(() => cronFromUnknown(value)).not.toThrow();
        expect(() => cronDeliveryTargetsFromApi(value)).not.toThrow();
      }),
      { numRuns: 10_000 },
    );
  }, 15_000);
});
