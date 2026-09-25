import Foundation

/// What a chat in the drawer is waiting on, if anything: one state, the most
/// pressing, so a glance down Recents says where to go back to.
///
/// In order: something only the person can answer (a permission, a question
/// the agent asked); a reply still being written, on this phone or out of
/// sight; a reply that failed or was cut off; a reply that finished while the
/// person was elsewhere; something typed and never sent.
enum ChatAttention: Equatable, Sendable {
    case needsYou
    case working
    case interrupted
    case newReply
    case draft

    /// - Parameters:
    ///   - isActive: the chat on screen; what is in front of him needs no mark.
    ///   - sending: a reply this phone is following.
    ///   - workingOutOfSight: Hermes running a turn here that nothing follows.
    ///   - waitingQuestion: a clarify question in this chat has no answer yet.
    ///   - unseenReply: a reply ended here while another chat was on screen.
    ///   - hasDraft: text left in this chat's composer.
    nonisolated static func of(
        _ chat: Conversation,
        isActive: Bool,
        sending: Bool,
        workingOutOfSight: Bool,
        waitingQuestion: Bool,
        unseenReply: Bool,
        hasDraft: Bool
    ) -> ChatAttention? {
        let last = chat.messages.last
        let asksPermission = chat.messages.contains { message in
            guard let approval = message.approval else { return false }
            return approval.resolving != true
        }
        if waitingQuestion || asksPermission { return .needsYou }
        if sending || workingOutOfSight || last?.awaitingRemote == true { return .working }
        if let last, last.role == .assistant, last.error != nil || last.incomplete {
            return .interrupted
        }
        if isActive { return nil }
        if unseenReply { return .newReply }
        if hasDraft { return .draft }
        return nil
    }
}
