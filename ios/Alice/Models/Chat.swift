import Foundation

/// Something the reader attached to a message.
///
/// The bytes live with the conversation rather than as a file reference: a
/// photo picked from the library can be deleted from it, and a conversation
/// that then shows a broken thumbnail is worse than one that carries its own
/// copy. Images are downscaled before they get here.
struct Attachment: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case image, file
    }

    let id: String
    var name: String
    var mime: String
    var kind: Kind
    var data: Data

    /// What the OpenAI-compatible content array expects for an image.
    var dataURL: String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// The contents, if this is something a model can read as text. Mirrors
    /// the web client, which inlines text files into the prompt rather than
    /// pretending the agent can open an attachment.
    var textContents: String? {
        let textual = mime.hasPrefix("text/")
            || mime.range(of: "json|javascript|typescript|xml|yaml|csv",
                          options: [.regularExpression, .caseInsensitive]) != nil
            || name.range(of: "\\.(md|markdown|json|csv|ts|tsx|js|jsx|py|html|css|xml|ya?ml|txt)$",
                          options: [.regularExpression, .caseInsensitive]) != nil
        guard textual, let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.prefix(50_000))
    }
}

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

    enum RunStatus: String, Hashable, Sendable, Codable {
        case started
        case queued
        case running
        case waitingForApproval = "waiting_for_approval"
        case stopping
        case completed
        case failed
        case cancelled

        var isTerminal: Bool {
            self == .completed || self == .failed || self == .cancelled
        }
    }

    enum ApprovalChoice: String, CaseIterable, Hashable, Sendable, Codable {
        case once
        case session
        case always
        case deny
    }

    struct Approval: Hashable, Sendable, Codable {
        var runID: String
        var title: String
        var detail: String?
        var command: String?
        var choices: [ApprovalChoice]
        /// UI/network state is optional so conversations written before this
        /// field existed continue to decode without a migration.
        var resolving: Bool?
        var error: String?
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
    var attachments: [Attachment] = []
    var botName: String? = nil
    /// Durable Hermes run state. Optional fields preserve compatibility with
    /// conversations saved by older builds.
    var runID: String? = nil
    var runStatus: RunStatus? = nil
    var approval: Approval? = nil
}

struct Conversation: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// When it was last opened, which is not when it was last written to: a
    /// conversation you reread today should come back before one you replied
    /// in last week. Absent on anything saved before this was recorded.
    var openedAt: Date?
    /// Kept at the top of the drawer, above everything else.
    var pinned: Bool = false
    /// The project this chat is filed under. Local: the agent's projects group
    /// its own sessions, and a conversation started on this phone is not one
    /// of those — this borrows the names so both read the same way.
    var project: String?
    var messages: [Message] = []
    var botName: String? = nil
    var isChannel: Bool? = false
    var channelBots: [String]? = []

    var isBotChat: Bool {
        if let botName, !botName.isEmpty { return true }
        if isChannel == true { return true }
        return false
    }

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
    case run(id: String, status: Message.RunStatus, output: String?)
    case approval(Message.Approval)
    case failure(message: String, limit: ModelLimit?)
}
