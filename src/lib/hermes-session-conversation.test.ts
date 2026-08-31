import { describe, expect, it } from "vitest";
import { importHermesSessionConversation } from "./hermes-session-conversation";
import type { Conversation } from "./types";

describe("Hermes session conversation import", () => {
  it("imports only visible user and assistant messages", () => {
    const result = importHermesSessionConversation(
      [],
      {
        sessionId: "session-1",
        title: "Research",
        messages: [
          { id: "1", role: "system", content: "secret" },
          {
            id: "2",
            role: "user",
            content: "Question",
            timestamp: "2026-08-30T10:00:00.000Z",
          },
          { id: "3", role: "tool", content: "raw result" },
          { id: "4", role: "assistant", content: "Answer" },
        ],
      },
      () => "alice-1",
      42,
    );
    expect(result.activeId).toBe("alice-1");
    expect(result.conversations[0]).toMatchObject({
      id: "alice-1",
      title: "Research",
      hermesSessionId: "session-1",
      messages: [
        { role: "user", content: "Question", createdAt: 1788084000000 },
        { role: "assistant", content: "Answer", createdAt: 45 },
      ],
    });
  });

  it("refreshes an existing imported session instead of duplicating it", () => {
    const existing: Conversation = {
      id: "alice-existing",
      title: "Old",
      createdAt: 1,
      updatedAt: 2,
      messages: [],
      pinned: true,
      hermesSessionId: "session-1",
    };
    const result = importHermesSessionConversation(
      [existing],
      {
        sessionId: "session-1",
        title: "Updated",
        messages: [{ id: "1", role: "assistant", content: "Fresh" }],
      },
      () => "unused",
      50,
    );
    expect(result.activeId).toBe("alice-existing");
    expect(result.conversations).toHaveLength(1);
    expect(result.conversations[0]).toMatchObject({
      title: "Updated",
      pinned: true,
      updatedAt: 50,
      messages: [{ content: "Fresh" }],
    });
  });
});
