import Foundation

extension AppStore {
    /// Start locally; create the remote session only when the person sends.
    /// Draft switching saves the previous chat's text and attachments normally.
    @discardableResult
    func openAgentTaskConversation(for bot: BotRow) -> String {
        let now = Date()
        let id = UUID().uuidString
        let task = Conversation(
            id: id, title: String(localized: "New Agent"), createdAt: now, updatedAt: now,
            botName: bot.name, agentTaskID: id
        )
        conversations.insert(task, at: 0)
        activeID = id
        persistConversationsImmediately()
        return id
    }

    func openAgentTask(_ task: Conversation, source: WebSocketBotChatSource) async throws -> HomeChatSession {
        guard let profile = task.routedBotName, let taskID = task.agentTaskID else {
            throw HermesRPCClient.Failure(reason: "This conversation is not an agent task.")
        }
        let session = try await source.openAgentTask(
            profile: profile, taskID: taskID, storedID: task.hermesSessionID
        )
        guard let index = conversations.firstIndex(where: { $0.id == task.id }),
              conversations[index].routedBotName == profile,
              conversations[index].agentTaskID == taskID else {
            throw HermesRPCClient.Failure(reason: "This task is no longer open. Nothing was sent.")
        }
        conversations[index].hermesSessionID = session.storedID
        persistConversationsImmediately()
        return session
    }

    /// Read/retry the exact task. Only canonical chats may re-resolve by profile.
    func resolveConversationSession(
        _ conversationID: String, profile: String, source: WebSocketBotChatSource
    ) async throws -> CanonicalBotChat {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.routedBotName == profile else {
            throw HermesRPCClient.Failure(reason: "This conversation is no longer available.")
        }
        if conversation.isAgentTask {
            guard let id = conversation.hermesSessionID, !id.isEmpty else {
                throw HermesRPCClient.Failure(reason: "Send a message to start this task.")
            }
            return CanonicalBotChat(id: id)
        }
        return try await resolveBotChat(profile, source: source)
    }
}
