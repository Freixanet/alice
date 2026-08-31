import type { HermesSessionMessage } from "./hermes-live-types";
import type { Conversation, Message } from "./types";

export type HermesSessionImport = {
  sessionId: string;
  title: string;
  messages: HermesSessionMessage[];
};

export function importHermesSessionConversation(
  conversations: Conversation[],
  payload: HermesSessionImport,
  createId: () => string,
  now: number,
): { conversations: Conversation[]; activeId: string } {
  const sessionId = payload.sessionId.trim().slice(0, 160);
  if (!sessionId) throw new Error("Invalid Hermes session identifier");
  const messages = localMessagesFromHermes(sessionId, payload.messages, now);
  const existing = conversations.find(
    (conversation) => conversation.hermesSessionId === sessionId,
  );
  const title = payload.title.trim().slice(0, 80) || "Hermes session";

  if (existing) {
    return {
      activeId: existing.id,
      conversations: conversations.map((conversation) =>
        conversation.id === existing.id
          ? { ...conversation, title, messages, updatedAt: now }
          : conversation,
      ),
    };
  }

  const conversation: Conversation = {
    id: createId(),
    title,
    createdAt: messages[0]?.createdAt ?? now,
    updatedAt: now,
    messages,
    hermesSessionId: sessionId,
  };
  return {
    activeId: conversation.id,
    conversations: [conversation, ...conversations],
  };
}

function localMessagesFromHermes(
  sessionId: string,
  rows: HermesSessionMessage[],
  now: number,
): Message[] {
  return rows.flatMap((row, index) => {
    if (
      (row.role !== "user" && row.role !== "assistant") ||
      !row.content.trim()
    ) {
      return [];
    }
    const parsed = row.timestamp ? Date.parse(row.timestamp) : Number.NaN;
    return [
      {
        id: `hermes:${sessionId}:${row.id}:${index}`,
        role: row.role,
        content: row.content,
        createdAt: Number.isFinite(parsed) ? parsed : now + index,
      },
    ];
  });
}
