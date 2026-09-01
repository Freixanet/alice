// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { afterEach, describe, expect, it } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Switch } from "./switch";

afterEach(cleanup);

describe("Switch", () => {
  it("keeps a circular thumb and preserves switch behavior", async () => {
    const user = userEvent.setup();
    const { container } = render(<Switch aria-label="Notifications" />);
    const control = screen.getByRole("switch", { name: "Notifications" });
    const thumb = container.querySelector(".alice-switch-thumb");

    expect(thumb).toHaveClass("rounded-full");
    expect(thumb).not.toHaveClass("rounded-md");
    expect(control).toHaveAttribute("aria-checked", "false");

    await user.click(control);

    expect(control).toHaveAttribute("aria-checked", "true");
  });
});
