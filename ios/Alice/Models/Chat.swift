import Foundation

/// One turn in a conversation. Mirrors the web model closely enough that a
/// conversation exported from one client reads correctly in the other.
struct Message: Identifiable, Hashable, Sendable, Codable {
    enum Role: String, Hashable, Sendable, Codable {
        case user, assistant
    }

    struct ToolCall: Identifiable, Hashable, Sendable, Codable {
        enum Status: String, Hashable, Sendable, Codable {
            case start, done
        }

        let id: String
        var name: String
        var status: Status
        var detail: String?
    }

    let id: String
    var role: Role
    var content: String
    var createdAt: Date
    var pending: Bool = false
    var tools: [ToolCall] = []
    var error: String?
    /// Set when the failure was a model limit, so the bubble can say whether
    /// waiting is worth it rather than showing one generic apology.
    var errorLimit: ModelLimit?
    var incomplete: Bool = false
}

struct Conversation: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message] = []

    static func blank(title: String = "New chat") -> Conversation {
        let now = Date()
        return Conversation(
            id: UUID().uuidString, title: title, createdAt: now, updatedAt: now
        )
    }
}

/// Events the chat transport yields while a reply streams in.
enum ChatEvent: Sendable {
    case delta(String)
    case tool(id: String, name: String, status: Message.ToolCall.Status, detail: String?)
    case run(id: String, status: String, output: String?)
    case failure(message: String, limit: ModelLimit?)
}
