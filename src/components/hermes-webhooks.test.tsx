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
import { HermesWebhooksPanel } from "./hermes-webhooks";

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

describe("HermesWebhooksPanel", () => {
  it("creates a subscription and forgets its one-time secret on close", async () => {
    mutateHermes.mockResolvedValue({
      ok: true,
      secret: "one-time-secret",
      url: "https://hermes.example/webhooks/github-push",
    });
    const onChanged = vi.fn().mockResolvedValue(undefined);
    render(
      <HermesWebhooksPanel
        writable
        state={{ enabled: true, subscriptions: [] }}
        onChanged={onChanged}
      />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: "connect.webhookCreate" }),
    );
    fireEvent.change(screen.getByLabelText("connect.webhookName"), {
      target: { value: "GitHub Push" },
    });
    fireEvent.change(screen.getByLabelText("connect.webhookEvents"), {
      target: { value: "push, pull_request" },
    });
    fireEvent.click(
      screen.getAllByRole("button", { name: "connect.webhookCreate" })[0]!,
    );

    await vi.waitFor(() =>
      expect(mutateHermes).toHaveBeenCalledWith({
        action: "webhook-create",
        name: "github-push",
        description: undefined,
        events: ["push", "pull_request"],
        prompt: undefined,
        skills: undefined,
        deliver: "log",
        deliverOnly: false,
        deliverChatId: undefined,
      }),
    );
    expect(await screen.findByText("one-time-secret")).toBeInTheDocument();
    expect(onChanged).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole("button", { name: "common.done" }));
    await vi.waitFor(() =>
      expect(screen.queryByText("one-time-secret")).not.toBeInTheDocument(),
    );
  });

  it("requires contextual confirmation before deleting", async () => {
    mutateHermes.mockResolvedValue({ ok: true });
    render(
      <HermesWebhooksPanel
        writable
        state={{
          enabled: true,
          subscriptions: [
            {
              name: "deploy",
              description: "Deploy events",
              events: ["push"],
              deliver: "log",
              deliverOnly: false,
              prompt: "",
              skills: [],
              secretSet: true,
              enabled: true,
            },
          ],
        }}
        onChanged={vi.fn().mockResolvedValue(undefined)}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "common.delete" }));
    expect(mutateHermes).not.toHaveBeenCalled();
    fireEvent.click(
      screen.getByRole("button", { name: "connect.webhookConfirmDelete" }),
    );

    await vi.waitFor(() =>
      expect(mutateHermes).toHaveBeenCalledWith({
        action: "webhook-delete",
        name: "deploy",
        confirm: true,
      }),
    );
  });
});
