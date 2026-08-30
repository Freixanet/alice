// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { McpServerDialog } from "./mcp-server-dialog";

vi.mock("@/lib/use-i18n", () => ({
  useT: () => (key: string) => key,
}));

afterEach(cleanup);

describe("McpServerDialog", () => {
  it("submits a valid stdio server without retaining its secret", async () => {
    const onSave = vi.fn().mockResolvedValue(null);
    const onOpenChange = vi.fn();
    render(
      <McpServerDialog open onOpenChange={onOpenChange} onSave={onSave} />,
    );

    fireEvent.change(screen.getByLabelText("addons.name"), {
      target: { value: "Local tools" },
    });
    fireEvent.click(screen.getByRole("button", { name: "addons.stdio" }));
    fireEvent.change(screen.getByLabelText("addons.command"), {
      target: { value: "npx" },
    });
    fireEvent.change(screen.getByLabelText("addons.args"), {
      target: { value: "-y\n@scope/server" },
    });
    fireEvent.change(screen.getByPlaceholderText("API_KEY=value"), {
      target: { value: "TOKEN=secret" },
    });
    fireEvent.click(screen.getByRole("button", { name: "addons.add" }));

    await vi.waitFor(() =>
      expect(onSave).toHaveBeenCalledWith({
        action: "mcp-create",
        name: "Local tools",
        command: "npx",
        args: ["-y", "@scope/server"],
        env: { TOKEN: "secret" },
        auth: "none",
      }),
    );
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it("keeps malformed environment data client-side", async () => {
    const onSave = vi.fn();
    render(<McpServerDialog open onOpenChange={vi.fn()} onSave={onSave} />);
    fireEvent.change(screen.getByLabelText("addons.name"), {
      target: { value: "Remote" },
    });
    fireEvent.change(screen.getByLabelText("addons.url"), {
      target: { value: "https://mcp.example.test" },
    });
    fireEvent.change(screen.getByPlaceholderText("API_KEY=value"), {
      target: { value: "BAD-NAME=secret" },
    });
    fireEvent.click(screen.getByRole("button", { name: "addons.add" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "addons.validation.env",
    );
    expect(onSave).not.toHaveBeenCalled();
  });
});
