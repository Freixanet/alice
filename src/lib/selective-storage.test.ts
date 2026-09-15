import { describe, expect, it, vi } from "vitest";
import { createStore } from "zustand/vanilla";
import { persist } from "zustand/middleware";
import { createSelectiveJSONStorage } from "./selective-storage";

function sink() {
  return { getItem: () => null, setItem: vi.fn(), removeItem: vi.fn() };
}

describe("selective persistence", () => {
  it("does not rewrite conversation history while a person types a transient draft", () => {
    const disk = sink();
    const storage = createSelectiveJSONStorage<{ messages: string[] }>(
      () => disk,
      () => "a",
    );
    const store = createStore(
      persist(() => ({ messages: ["saved"], draft: "" }), {
        name: "chat",
        storage,
        skipHydration: true,
        partialize: ({ messages }) => ({ messages }),
      }),
    );
    store.setState({ messages: ["saved", "new"] });
    for (const draft of ["A", "Al", "Ali", "Alice"]) store.setState({ draft });
    expect(disk.setItem).toHaveBeenCalledTimes(1);
    expect(JSON.parse(disk.setItem.mock.calls[0]![1]).state).toEqual({
      messages: ["saved", "new"],
    });
    store.setState({ messages: ["saved", "new", "reply"] });
    expect(disk.setItem).toHaveBeenCalledTimes(2);
  });

  it("persists identical state for a different account and after a removal", async () => {
    const disk = sink();
    let account = "a";
    const storage = createSelectiveJSONStorage<{ theme: string }>(
      () => disk,
      () => account,
    )!;
    const value = { state: { theme: "dark" }, version: 1 };
    await storage.setItem("chat", value);
    account = "b";
    await storage.setItem("chat", value);
    storage.removeItem("chat");
    await storage.setItem("chat", value);
    expect(disk.setItem).toHaveBeenCalledTimes(3);
  });

  it("retries an identical state after a failed write", async () => {
    const disk = sink();
    disk.setItem.mockRejectedValueOnce(new Error("disk unavailable"));
    const storage = createSelectiveJSONStorage<{ theme: string }>(
      () => disk,
      () => "a",
    )!;
    const value = { state: { theme: "dark" } };
    await expect(storage.setItem("chat", value)).rejects.toThrow(
      "disk unavailable",
    );
    await storage.setItem("chat", value);
    expect(disk.setItem).toHaveBeenCalledTimes(2);
  });
});
