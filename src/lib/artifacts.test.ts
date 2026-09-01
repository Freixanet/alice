import { describe, expect, it } from "vitest";
import { artifactsFromConversations } from "./artifacts";
import type { Conversation } from "./types";

describe("artifactsFromConversations", () => {
  it("indexes attachments, unique links, and substantial fenced code", () => {
    const conversations: Conversation[] = [
      {
        id: "chat-1",
        title: "Launch",
        createdAt: 1,
        updatedAt: 2,
        messages: [
          {
            id: "message-1",
            role: "assistant",
            createdAt: 2,
            content: `See https://example.com/report.\n\n\`\`\`ts\n${"const value = 1;\n".repeat(12)}\`\`\``,
            attachments: [
              {
                id: "asset-1",
                name: "chart.png",
                mime: "image/png",
                kind: "image",
                dataUrl: "data:image/png;base64,AA==",
              },
            ],
          },
        ],
      },
    ];

    expect(artifactsFromConversations(conversations)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "image", label: "chart.png" }),
        expect.objectContaining({
          kind: "link",
          value: "https://example.com/report",
        }),
        expect.objectContaining({ kind: "code", language: "ts" }),
      ]),
    );
  });
});
