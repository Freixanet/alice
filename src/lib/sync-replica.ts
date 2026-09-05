import type { Conversation, Message } from "./types";

export type ConversationReplicaV2 = {
  version: 2;
  /** Monotonic local version for conversation metadata and deletion races. */
  updatedAt: number;
  conversation: Conversation;
  /** Last mutation time for each live message. */
  messageVersions: Record<string, number>;
  /** Last removal time for messages removed by truncate/edit operations. */
  messageTombstones: Record<string, number>;
};

function messageVersion(
  replica: ConversationReplicaV2,
  message: Message,
): number {
  return replica.messageVersions[message.id] ?? message.createdAt;
}

function stableMessage(message: Message) {
  return JSON.stringify(message);
}

function chooseMessage(
  left: { message: Message; version: number } | undefined,
  right: { message: Message; version: number } | undefined,
) {
  if (!left) return right;
  if (!right) return left;
  if (left.version !== right.version)
    return left.version > right.version ? left : right;
  return stableMessage(left.message) <= stableMessage(right.message) ? left : right;
}

function stableMetadata(conversation: Conversation) {
  const { messages: _messages, ...metadata } = conversation;
  return JSON.stringify(metadata);
}

function metadataWinner(
  left: ConversationReplicaV2,
  right: ConversationReplicaV2,
) {
  if (left.updatedAt !== right.updatedAt)
    return left.updatedAt > right.updatedAt ? left : right;
  return stableMetadata(left.conversation) <= stableMetadata(right.conversation)
    ? left
    : right;
}

/**
 * Merge two full encrypted replicas without making the whole conversation the
 * conflict unit. Distinct messages converge independently, while concurrent
 * edits to the same message use that message's own mutation clock.
 */
export function mergeConversationReplicas(
  left: ConversationReplicaV2,
  right: ConversationReplicaV2,
): ConversationReplicaV2 {
  if (left.conversation.id !== right.conversation.id) {
    throw new Error("Cannot merge replicas for different conversations");
  }

  const primary = metadataWinner(left, right);
  const live = new Map<string, { message: Message; version: number }>();
  for (const message of left.conversation.messages) {
    live.set(message.id, { message, version: messageVersion(left, message) });
  }
  for (const message of right.conversation.messages) {
    live.set(
      message.id,
      chooseMessage(live.get(message.id), {
        message,
        version: messageVersion(right, message),
      })!,
    );
  }

  const messageTombstones: Record<string, number> = {
    ...left.messageTombstones,
  };
  for (const [id, version] of Object.entries(right.messageTombstones)) {
    messageTombstones[id] = Math.max(messageTombstones[id] ?? 0, version);
  }

  const messages: Message[] = [];
  const messageVersions: Record<string, number> = {};
  for (const [id, candidate] of live) {
    if ((messageTombstones[id] ?? 0) >= candidate.version) continue;
    messages.push(candidate.message);
    messageVersions[id] = candidate.version;
  }
  messages.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));

  const conversation: Conversation = {
    ...primary.conversation,
    updatedAt: Math.max(
      left.conversation.updatedAt,
      right.conversation.updatedAt,
      left.updatedAt,
      right.updatedAt,
    ),
    messages,
  };

  return {
    version: 2,
    updatedAt: Math.max(left.updatedAt, right.updatedAt),
    conversation,
    messageVersions,
    messageTombstones,
  };
}

export function legacyConversationReplica(
  conversation: Conversation,
): ConversationReplicaV2 {
  const messageVersions: Record<string, number> = {};
  for (const message of conversation.messages) {
    // Legacy records only had one clock for the whole conversation, so use it
    // conservatively during migration rather than inventing message history.
    messageVersions[message.id] = Math.max(
      message.createdAt,
      conversation.updatedAt,
    );
  }
  return {
    version: 2,
    updatedAt: conversation.updatedAt,
    conversation,
    messageVersions,
    messageTombstones: {},
  };
}
