// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useHermes } from "@/lib/store";
import { HermesProfilesSettings } from "./hermes-profiles-settings";

const { mutateHermes, readHermesProfiles, readHermesProfileSoul } = vi.hoisted(
  () => ({
    mutateHermes: vi.fn(),
    readHermesProfiles: vi.fn(),
    readHermesProfileSoul: vi.fn(),
  }),
);

vi.mock("@/lib/hermes-live", async (importOriginal) => ({
  ...(await importOriginal()),
  mutateHermes,
  readHermesProfiles,
  readHermesProfileSoul,
}));

vi.mock("@/lib/use-i18n", () => ({
  useLocale: () => "en",
  useT: () => (key: string, vars?: Record<string, string | number>) =>
    vars?.count === undefined ? key : `${key}:${vars.count}`,
}));

const state = {
  active: "default",
  current: "default",
  profiles: [
    {
      name: "default",
      displayName: "Default",
      description: "Primary profile",
      descriptionAuto: false,
      isDefault: true,
      skillCount: 3,
      hasEnv: true,
      gatewayRunning: true,
    },
    {
      name: "research",
      displayName: "Research",
      description: "Evidence",
      descriptionAuto: false,
      isDefault: false,
      skillCount: 7,
      hasEnv: false,
      gatewayRunning: false,
    },
  ],
};

beforeEach(() => {
  useHermes.setState({
    gatewayOn: true,
    gatewayStatus: "live",
    profile: "default",
    gatewayMeta: {
      model: "hermes-agent",
      probedAt: Date.now(),
      mode: "proxy",
      manifest: {
        version: "0.21.0",
        normalizedVersion: "0.21.0",
        compatibility: "current",
        capabilities: { profiles: true },
        advertised: ["profiles"],
      },
    },
  });
  readHermesProfiles.mockResolvedValue({ ok: true, state });
  readHermesProfileSoul.mockResolvedValue({
    ok: true,
    content: "Be rigorous.",
    exists: true,
  });
  mutateHermes.mockResolvedValue({ ok: true });
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

describe("HermesProfilesSettings", () => {
  it("selects a management scope locally and activates it only on request", async () => {
    const user = userEvent.setup();
    render(<HermesProfilesSettings />);

    await user.click(await screen.findByRole("button", { name: /Research/ }));
    expect(useHermes.getState().profile).toBe("research");
    expect(mutateHermes).not.toHaveBeenCalled();

    await user.click(
      await screen.findByRole("button", {
        name: "settings.profileMakeDefault",
      }),
    );
    expect(mutateHermes).toHaveBeenCalledWith({
      action: "profile-activate",
      name: "research",
    });
  });

  it("does not offer deletion for the active or running profile", async () => {
    render(<HermesProfilesSettings />);
    expect(await screen.findByText("Default")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "settings.profileDelete" }),
    ).not.toBeInTheDocument();
  });
});
