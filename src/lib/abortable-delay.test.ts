import { describe, expect, it, vi } from "vitest";
import { abortableDelay } from "./abortable-delay";

describe("abortable delay", () => {
  it("resolves after the requested delay", async () => {
    vi.useFakeTimers();
    const pending = abortableDelay(250);
    await vi.advanceTimersByTimeAsync(250);
    await expect(pending).resolves.toBeUndefined();
    vi.useRealTimers();
  });

  it("clears its timer immediately when aborted", async () => {
    vi.useFakeTimers();
    const controller = new AbortController();
    const pending = abortableDelay(10_000, controller.signal);
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    expect(vi.getTimerCount()).toBe(0);
    vi.useRealTimers();
  });
});
