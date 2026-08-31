// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { HermesChannelsPanel } from "./hermes-channels";

const mutateHermes = vi.hoisted(() => vi.fn());

vi.mock("@/lib/hermes-live", async (importOriginal) => ({
  ...(await importOriginal()),
  mutateHermes,
}));

vi.mock("@/lib/use-i18n", () => ({
  useLocale: () => "en",
  useT: () => (key: string) => key,
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
afterEach(() => {
  cleanup();
  mutateHermes.mockReset();
});

const telegram = {
  id: "telegram",
  name: "Telegram",
  enabled: true,
  configured: true,
  state: "connected",
  gatewayRunning: true,
  envVars: [
    {
      key: "TELEGRAM_BOT_TOKEN",
      required: true,
      isSet: true,
      redactedValue: "••••1234",
      description: "Token from BotFather",
      prompt: "Bot token",
      isPassword: true,
      advanced: false,
    },
  ],
};

describe("HermesChannelsPanel", () => {
  it("never prefills a saved secret and only sends a replacement", async () => {
    mutateHermes.mockResolvedValue({ ok: true });
    const onChanged = vi.fn().mockResolvedValue(undefined);
    render(
      <HermesChannelsPanel
        channels={[telegram]}
        writable
        onChanged={onChanged}
      />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: "connect.channelConfigure" }),
    );
    const token = screen.getByLabelText(/Bot token/);
    expect(token).toHaveValue("");
    expect(screen.queryByDisplayValue("••••1234")).not.toBeInTheDocument();
    fireEvent.change(token, { target: { value: "new-secret" } });
    fireEvent.click(
      screen.getByRole("button", { name: "connect.saveSession" }),
    );

    await vi.waitFor(() =>
      expect(mutateHermes).toHaveBeenCalledWith({
        action: "channel-update",
        platformId: "telegram",
        enabled: true,
        env: { TELEGRAM_BOT_TOKEN: "new-secret" },
        clearEnv: undefined,
      }),
    );
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it("surfaces Hermes channel test results without treating them as saves", async () => {
    mutateHermes.mockResolvedValue({
      ok: true,
      channelTest: {
        ok: false,
        state: "disconnected",
        message: "Restart the gateway.",
      },
    });
    render(
      <HermesChannelsPanel
        channels={[telegram]}
        writable
        onChanged={vi.fn().mockResolvedValue(undefined)}
      />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: "connect.channelTest" }),
    );

    expect(await screen.findByText("Restart the gateway.")).toBeInTheDocument();
    expect(mutateHermes).toHaveBeenCalledWith({
      action: "channel-test",
      platformId: "telegram",
    });
  });
});
