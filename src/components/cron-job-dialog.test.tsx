// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import type { HermesCronRow } from "@/lib/hermes-live-types";
import { CronJobDialog } from "./cron-job-dialog";

vi.mock("@/lib/use-i18n", () => ({
  useT: () => (key: string) =>
    ({
      "cron.editTitle": "Edit scheduled job",
      "cron.createTitle": "Create a scheduled job",
      "cron.editDescription": "Edit description",
      "cron.createDescription": "Create description",
      "cron.name": "Name",
      "cron.namePlaceholder": "Morning briefing",
      "cron.mode": "Execution mode",
      "cron.modeAgent": "Agent",
      "cron.modeScript": "Script only",
      "cron.script": "Script file",
      "cron.scriptPlaceholder": "memory-watchdog.sh",
      "cron.scriptHint": "Script hint",
      "cron.instructions": "Instructions",
      "cron.instructionsPlaceholder": "Instructions placeholder",
      "cron.frequency": "Frequency",
      "cron.daily": "Every day",
      "cron.weekdays": "Weekdays",
      "cron.weekly": "Every Monday",
      "cron.hourly": "Every hour",
      "cron.custom": "Custom schedule",
      "cron.schedule": "Schedule",
      "cron.time": "Time",
      "cron.delivery": "Deliver result to",
      "cron.deliveryLocal": "Local (save only)",
      "cron.deliveryUnavailable": "Unavailable",
      "cron.skills": "Skills",
      "cron.advanced": "Advanced options",
      "cron.model": "Model override (optional)",
      "cron.provider": "Provider override (optional)",
      "cron.toolsets": "Toolsets",
      "cron.preScript": "Pre-run script (optional)",
      "cron.workdir": "Working folder (optional)",
      "cron.continuity": "Continuity",
      "cron.continuityHint": "Remember the previous result",
      "cron.monitorMode": "Monitor mode",
      "cron.monitorOff": "Off",
      "cron.monitorScript": "Watch a script",
      "cron.monitorUrl": "Watch a URL",
      "cron.monitorScriptPath": "Monitor script",
      "cron.monitorUrlAddress": "Monitor URL",
      "cron.monitorHint": "Skip unchanged output",
      "cron.reasoningEffort": "Reasoning effort",
      "cron.reasoningDefault": "Use the profile default",
      "cron.notepadHint": "A durable notepad is automatic",
      "cron.cancel": "Cancel",
      "cron.save": "Save changes",
      "cron.saving": "Saving…",
      "cron.create": "Create job",
      "cron.creating": "Creating…",
    })[key] ?? key,
}));

beforeAll(() => {
  vi.stubGlobal(
    "ResizeObserver",
    class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  );
});

afterAll(() => vi.unstubAllGlobals());

afterEach(cleanup);

const job: HermesCronRow = {
  id: "morning",
  name: "Morning briefing",
  prompt: "Summarize the day",
  schedule: "0 9 * * 1-5",
  deliver: "telegram",
  skills: ["research"],
  model: "gpt-5.6",
  provider: "openai",
  script: "prepare.py",
  workdir: "/workspace",
  enabledToolsets: ["web"],
  noAgent: false,
  continuity: true,
  monitorUrl: "https://example.com/releases",
  reasoningEffort: "high",
  enabled: true,
  state: "scheduled",
};

describe("CronJobDialog", () => {
  it("round-trips every supported field while editing", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn(async () => undefined);
    render(
      <CronJobDialog
        open
        job={job}
        skills={[
          {
            id: "research",
            name: "research",
            title: "Research",
            description: "Research sources",
            group: "research",
            groupLabel: "Research",
            enabled: true,
          },
        ]}
        toolsets={[
          {
            id: "web",
            name: "web",
            label: "Web",
            description: "Search the web",
            enabled: true,
            tools: ["web_search"],
          },
        ]}
        deliveryTargets={[
          {
            id: "telegram",
            name: "Telegram",
            homeTargetSet: true,
          },
        ]}
        pantheon
        pending={false}
        error={null}
        onOpenChange={vi.fn()}
        onSave={onSave}
      />,
    );

    expect(
      screen.getByRole("heading", { name: "Edit scheduled job" }),
    ).toBeVisible();
    expect(screen.getByLabelText("Deliver result to")).toHaveValue("telegram");
    expect(screen.getByLabelText("Research")).toBeChecked();
    await user.clear(screen.getByLabelText("Name"));
    await user.type(screen.getByLabelText("Name"), "Weekday briefing");
    await user.click(screen.getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(onSave).toHaveBeenCalledOnce());
    expect(onSave).toHaveBeenCalledWith({
      name: "Weekday briefing",
      prompt: "Summarize the day",
      schedule: "0 9 * * 1-5",
      deliver: "telegram",
      skills: ["research"],
      model: "gpt-5.6",
      provider: "openai",
      script: "prepare.py",
      workdir: "/workspace",
      enabledToolsets: ["web"],
      noAgent: false,
      continuity: true,
      monitorScript: undefined,
      monitorUrl: "https://example.com/releases",
      reasoningEffort: "high",
    });
  });

  it("requires a script before saving a no-agent job", async () => {
    const user = userEvent.setup();
    render(
      <CronJobDialog
        open
        job={null}
        skills={[]}
        toolsets={[]}
        deliveryTargets={[]}
        pantheon
        pending={false}
        error={null}
        onOpenChange={vi.fn()}
        onSave={vi.fn(async () => undefined)}
      />,
    );
    await user.type(screen.getByLabelText("Name"), "Watch memory");
    await user.click(screen.getByRole("button", { name: "Script only" }));
    expect(screen.getByRole("button", { name: "Create job" })).toBeDisabled();
    await user.type(
      screen.getByPlaceholderText("memory-watchdog.sh"),
      "memory-watchdog.sh",
    );
    expect(screen.getByRole("button", { name: "Create job" })).toBeEnabled();
  });
});
