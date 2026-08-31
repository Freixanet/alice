// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { HermesMcpCatalogRow } from "@/lib/hermes-live-types";
import { McpCatalogDialog } from "./mcp-catalog-dialog";

vi.mock("@/lib/use-i18n", () => ({
  useT: () => (key: string) => key,
}));

afterEach(cleanup);

const entry: HermesMcpCatalogRow = {
  name: "github",
  description: "GitHub tools",
  source: "https://github.com/example/mcp",
  transport: "stdio",
  authType: "header",
  requiredEnv: [{ name: "GITHUB_TOKEN", prompt: "Token", required: true }],
  command: "uvx",
  args: ["mcp-github"],
  bootstrap: [],
  needsInstall: true,
  installed: false,
  enabled: false,
};

describe("McpCatalogDialog", () => {
  it("requires credentials and sends them only to the install callback", async () => {
    const onInstall = vi.fn().mockResolvedValue(true);
    render(
      <McpCatalogDialog
        open
        entries={[entry]}
        diagnostics={[]}
        loading={false}
        error={null}
        busyName={null}
        onOpenChange={vi.fn()}
        onInstall={onInstall}
      />,
    );

    const install = screen.getByRole("button", {
      name: "addons.catalogInstall",
    });
    expect(install).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Token *"), {
      target: { value: "secret" },
    });
    expect(install).toBeEnabled();
    fireEvent.click(install);

    await vi.waitFor(() =>
      expect(onInstall).toHaveBeenCalledWith(entry, {
        GITHUB_TOKEN: "secret",
      }),
    );
    await vi.waitFor(() =>
      expect(screen.getByLabelText("Token *")).toHaveValue(""),
    );
  });

  it("clears secret fields whenever the dialog closes", async () => {
    const props = {
      entries: [entry],
      diagnostics: [],
      loading: false,
      error: null,
      busyName: null,
      onOpenChange: vi.fn(),
      onInstall: vi.fn().mockResolvedValue(false),
    };
    const view = render(<McpCatalogDialog open {...props} />);
    fireEvent.change(screen.getByLabelText("Token *"), {
      target: { value: "secret" },
    });
    view.rerender(<McpCatalogDialog open={false} {...props} />);
    view.rerender(<McpCatalogDialog open {...props} />);
    await vi.waitFor(() =>
      expect(screen.getByLabelText("Token *")).toHaveValue(""),
    );
  });
});
