import Foundation

/// Sessions to read for unanswered requests, including turns sent with `@`.
/// A mention's session belongs to its reply, not to the surrounding chat.
enum PendingRequestSessions {
    struct Address: Hashable, Sendable {
        var profile: String?
        var sessionID: String
    }

    struct Target: Equatable, Sendable {
        var address: Address
        var conversationID: String
        var isMention: Bool
    }

    static func targets(
        in conversations: [Conversation],
        waitingConversations: Set<String> = [], waitingSessions: Set<Address> = []
    ) -> [Target] {
        var targets: [Target] = []
        var seen: Set<Address> = []
        func append(_ target: Target) {
            guard seen.insert(target.address).inserted else { return }
            targets.append(target)
        }

        // Prefer the chat that sent the mention when the agent's own chat
        // mirrors the same session. Read that session only once per sync.
        for chat in conversations {
            for message in chat.messages.reversed() where message.role == .assistant {
                guard let profile = message.mentionProfile, !profile.isEmpty,
                      let sessionID = message.mentionSessionID, !sessionID.isEmpty
                else { continue }
                let address = Address(profile: profile, sessionID: sessionID)
                guard message.pending || message.awaitingRemote || waitingSessions.contains(address)
                else { continue }
                append(Target(address: address, conversationID: chat.id, isMention: true))
            }
        }

        for chat in conversations {
            let reply = chat.messages.last(where: { $0.role == .assistant })
            let awaitsReply = reply.map { $0.pending || $0.awaitingRemote } ?? false
            guard chat.isAgentSessionChat
                || (chat.isHomeSessionChat && (awaitsReply || waitingConversations.contains(chat.id))),
                  let sessionID = chat.hermesSessionID, !sessionID.isEmpty
            else { continue }
            append(Target(
                address: Address(profile: chat.routedBotName, sessionID: sessionID),
                conversationID: chat.id, isMention: false
            ))
        }
        return targets
    }
}
