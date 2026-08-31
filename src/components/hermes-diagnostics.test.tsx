// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { HermesDiagnosticsPanel } from "./hermes-diagnostics";

const { readDiagnostics } = vi.hoisted(() => ({
  readDiagnostics: vi.fn(),
}));

vi.mock("@/lib/hermes-live", () => ({
  readHermesDiagnostics: (...args: unknown[]) => readDiagnostics(...args),
}));

vi.mock("@/lib/use-i18n", () => ({
  useLocale: () => "en",
  useT: () => (key: string) => key,
}));

afterEach(() => {
  cleanup();
  readDiagnostics.mockReset();
});

describe("HermesDiagnosticsPanel", () => {
  it("loads only on demand and exposes the safe diagnostic projection", async () => {
    readDiagnostics.mockResolvedValue({
      ok: true,
      diagnostics: {
        status: "ready",
        version: "0.21.0",
        gatewayState: "running",
        activeAgents: 1,
        busy: false,
        drainable: true,
        platforms: [{ id: "telegram", name: "Telegram", status: "connected" }],
      },
    });
    const user = userEvent.setup();
    render(<HermesDiagnosticsPanel />);

    expect(readDiagnostics).not.toHaveBeenCalled();
    const button = screen.getByRole("button", {
      name: "connect.showDiagnostics",
    });
    expect(button).toHaveAttribute("aria-expanded", "false");
    await user.click(button);

    expect(await screen.findByText("ready")).toBeInTheDocument();
    expect(screen.getByText("Telegram")).toBeInTheDocument();
    expect(screen.getByText("connected")).toBeInTheDocument();
    expect(readDiagnostics).toHaveBeenCalledOnce();
    expect(button).toHaveAttribute("aria-expanded", "true");
  });
});
