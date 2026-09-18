import Foundation

/// Hermes will not put a session on some models until the person agrees —
/// expensive ones, and Meta's contributor tier that trains on prompts.
///
/// That notice used to be thrown into the reply as if Alice had answered.
/// It is a confirmation, not a completion.
enum ModelConfirmation {
    struct Needed: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// A turn Alice is holding until the model is accepted.
    struct Pending: Equatable {
        var conversationID: String
        var replyID: String
        var text: String
        var attachments: [Attachment]
        var earlier: [Message]
        var message: String
    }

    static func notice(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 2_000 else { return nil }
        let folded = trimmed.uppercased()
        if folded.contains("CONTRIBUTOR TIER") { return trimmed }
        if folded.contains("TRAINS ON YOUR DATA") { return trimmed }
        return nil
    }

    static func needed(from error: Error) -> Needed? {
        if let needed = error as? Needed { return needed }
        if let notice = notice(in: error.localizedDescription) {
            return Needed(message: notice)
        }
        return nil
    }
}
