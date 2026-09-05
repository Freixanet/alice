// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { RadarIASetup } from "./radar-ia-setup";

vi.mock("@/lib/use-i18n", () => ({ useT: () => (key: string) => key }));
afterEach(cleanup);

it("prepares the default Barcelona request only after submission", () => {
  const onPrepare = vi.fn();
  render(<RadarIASetup onPrepare={onPrepare} />);
  expect(screen.getByLabelText("radar.time")).toHaveValue("10:00");
  expect(screen.getByLabelText("radar.zone")).toHaveValue("Europe/Madrid");
  expect(onPrepare).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "radar.prepare" }));
  expect(onPrepare).toHaveBeenCalledOnce();
  expect(onPrepare.mock.calls[0]![0]).toContain("10:00");
  expect(onPrepare.mock.calls[0]![0]).toContain("Europe/Madrid");
});

it("validates edits and carries the chosen schedule into the request", () => {
  const onPrepare = vi.fn();
  render(<RadarIASetup onPrepare={onPrepare} />);
  fireEvent.change(screen.getByLabelText("radar.zone"), {
    target: { value: "Bad/Zone" },
  });
  const button = screen.getByRole("button", { name: "radar.prepare" });
  expect(button).toBeDisabled();
  fireEvent.click(button);
  expect(onPrepare).not.toHaveBeenCalled();
  fireEvent.change(screen.getByLabelText("radar.zone"), {
    target: { value: "Europe/Paris" },
  });
  fireEvent.change(screen.getByLabelText("radar.time"), {
    target: { value: "11:30" },
  });
  fireEvent.click(button);
  expect(onPrepare.mock.calls[0]![0]).toContain("11:30");
  expect(onPrepare.mock.calls[0]![0]).toContain("Europe/Paris");
});
