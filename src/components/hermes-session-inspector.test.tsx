// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { HermesSessionInspector } from "./hermes-session-inspector";

const { readMessages } = vi.hoisted(() => ({ readMessages: vi.fn() }));

vi.mock("@/lib/hermes-live", () => ({
  readHermesSessionMessages: (...args: unknown[]) => readMessages(...args),
}));

vi.mock("@/lib/use-i18n", () => ({
  useLocale: () => "en",
  useT: () => (key: string) => key,
}));

afterEach(() => {
  cleanup();
  readMessages.mockReset();
});

describe("HermesSessionInspector", () => {
  it("loads on demand and renders remote content only as inert text", async () => {
    readMessages.mockResolvedValue({
      ok: true,
      sessionId: "session-1",
      messages: [
        {
          id: "message-1",
          role: "assistant",
          content: '<img src=x onerror="alert(1)">',
        },
      ],
    });
    const user = userEvent.setup();
    const { container } = render(
      <HermesSessionInspector sessionId="session-1" />,
    );

    const button = screen.getByRole("button", {
      name: "connect.inspectSession",
    });
    expect(button).toHaveAttribute("aria-expanded", "false");
    await user.click(button);

    expect(await screen.findByText(/<img src=x/)).toBeInTheDocument();
    expect(container.querySelector("img")).toBeNull();
    expect(readMessages).toHaveBeenCalledWith(
      expect.objectContaining({ sessionId: "session-1" }),
    );
    expect(button).toHaveAttribute("aria-expanded", "true");
  });
});
