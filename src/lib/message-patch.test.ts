import { describe, expect, it } from "vitest";
import { applyMessagePatch } from "./message-patch";
import type { Message } from "./types";

describe("message patches", () => {
  it("removes cleared optional state instead of persisting undefined", () => {
    const message: Message = {
      id: "m1",
      role: "assistant",
      content: "done",
      createdAt: 1,
      pending: true,
      approval: { title: "Approve", choices: ["once", "deny"] },
    };

    const next = applyMessagePatch(message, {
      pending: false,
      approval: undefined,
    });

    expect(next).toEqual({
      id: "m1",
      role: "assistant",
      content: "done",
      createdAt: 1,
      pending: false,
    });
    expect("approval" in next).toBe(false);
  });
});
