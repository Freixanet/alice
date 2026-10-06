import Foundation

extension AppStore {
    func beginReply(to message: Message) {
        guard !activeIsRecoveredHistory, message.role == .assistant, !message.pending,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let chat = shownConversation,
              chat.messages.contains(where: { $0.id == message.id }) else { return }
        if editingMessageID != nil { cancelEditing() }
        let profile = message.mentionProfile ?? message.botName
        let author = message.fromAgent ?? profile.map { botCurrentName(for: $0) } ?? "Alice"
        draftReply = MessageReply(conversationID: chat.id, messageID: message.id,
                                  author: author, content: message.content)
        draftReply?.remoteMessageID = message.remoteID
        replyFocusRequest += 1
    }

    func cancelReply() {
        draftReply = nil
        replyGestureMessageID = nil
    }

    var replySpotlightID: String? {
        if let replyGestureMessageID { return replyGestureMessageID }
        guard let quote = draftReply else { return nil }
        return shownConversation?.messages.first {
            $0.id == quote.messageID || (quote.remoteMessageID != nil && $0.remoteID == quote.remoteMessageID)
        }?.id
    }
}
