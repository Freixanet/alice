import type { Conversation } from "./types";

export type AliceArtifactKind = "file" | "image" | "link" | "code";

export type AliceArtifact = {
  id: string;
  kind: AliceArtifactKind;
  label: string;
  value: string;
  mime?: string;
  language?: string;
  conversationId: string;
  conversationTitle: string;
  messageId: string;
  createdAt: number;
};

const URL_PATTERN = /https?:\/\/[^\s<>()\]]+/gi;
const FENCE_PATTERN = /```([\w.+-]*)\n([\s\S]*?)```/g;

export function artifactsFromConversations(
  conversations: readonly Conversation[],
): AliceArtifact[] {
  const artifacts: AliceArtifact[] = [];
  const seen = new Set<string>();

  for (const conversation of conversations) {
    for (const message of conversation.messages) {
      for (const attachment of message.attachments ?? []) {
        const value = attachment.dataUrl ?? "";
        const key = `${conversation.id}:attachment:${attachment.id}`;
        if (seen.has(key)) continue;
        seen.add(key);
        artifacts.push({
          id: key,
          kind: attachment.kind === "image" ? "image" : "file",
          label: attachment.name,
          value,
          mime: attachment.mime,
          conversationId: conversation.id,
          conversationTitle: conversation.title,
          messageId: message.id,
          createdAt: message.createdAt,
        });
      }

      for (const match of message.content.matchAll(URL_PATTERN)) {
        const value = trimUrlPunctuation(match[0]);
        const key = `${conversation.id}:link:${value}`;
        if (!value || seen.has(key)) continue;
        seen.add(key);
        artifacts.push({
          id: key,
          kind: "link",
          label: linkLabel(value),
          value,
          conversationId: conversation.id,
          conversationTitle: conversation.title,
          messageId: message.id,
          createdAt: message.createdAt,
        });
      }

      let index = 0;
      for (const match of message.content.matchAll(FENCE_PATTERN)) {
        const content = (match[2] ?? "").trim();
        if (content.length < 160) continue;
        const language = (match[1] ?? "").trim().toLowerCase() || "text";
        const key = `${conversation.id}:code:${message.id}:${index++}`;
        artifacts.push({
          id: key,
          kind: "code",
          label: `${prettyLanguage(language)} · ${conversation.title}`,
          value: content,
          language,
          conversationId: conversation.id,
          conversationTitle: conversation.title,
          messageId: message.id,
          createdAt: message.createdAt,
        });
      }
    }
  }

  return artifacts.sort((left, right) => right.createdAt - left.createdAt);
}

function trimUrlPunctuation(value: string): string {
  return value.replace(/[.,;:!?]+$/g, "");
}

function linkLabel(value: string): string {
  try {
    const url = new URL(value);
    return `${url.hostname}${url.pathname === "/" ? "" : url.pathname}`;
  } catch {
    return value;
  }
}

function prettyLanguage(value: string): string {
  return value === "js"
    ? "JavaScript"
    : value === "ts"
      ? "TypeScript"
      : value === "tsx"
        ? "TSX"
        : value === "jsx"
          ? "JSX"
          : value.toUpperCase();
}
