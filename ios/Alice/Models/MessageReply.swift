import Foundation

/// A frozen, bounded quote. It belongs to one chat and survives deletion of the original.
struct MessageReply: Codable, Hashable, Sendable {
    var conversationID: String
    var messageID: String
    var author: String
    var content: String
    var remoteMessageID: String? = nil

    init(conversationID: String, messageID: String, author: String, content: String) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.author = author
        self.content = content.count > 6_000 ? String(content.prefix(6_000)) + "…" : content
    }

    func prompt(for answer: String) -> String { Self.prompt(for: answer, quotes: [self]) }

    static func prompt(for answer: String, quotes: [MessageReply]) -> String {
        guard !quotes.isEmpty else { return answer }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let quote = (try? encoder.encode(quotes)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "Replying to these earlier assistant messages (quoted context):\n\(quote)\n\nMy reply:\n\(answer)"
    }
}

extension Message {
    var outboundContent: String {
        role == .user ? MessageReply.prompt(for: content, quotes: quotedReplies ?? []) : content
    }
}

/// Kept separate from vertical scrolling and the navigation drawer.
enum MessageReplySwipe {
    static let threshold: CGFloat = 56
    static func starts(velocity: CGPoint) -> Bool {
        velocity.x > 50 && velocity.x > abs(velocity.y) * 1.5
    }
    static func completes(translation: CGFloat) -> Bool { translation >= threshold }
}
