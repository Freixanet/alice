import Foundation

/// Alice learned something after a reply, said under that reply in one plain sentence.
///
/// Hermes writes lessons as skills, often in a review after the conversation pauses; the plugin's
/// keeper applies them and records it in the action log (`skill.learned`). Only that is said: skill
/// names mean nothing to the person, and a lesson held back as unsafe is not theirs to judge in a chat.
enum LessonNotice {
    /// A lesson belongs to the last reply before it, if it came within this long of it.
    static let window: TimeInterval = 30 * 60

    static func said(in language: ChatLanguage) -> String {
        language.pick("I learned something for next time", "He aprendido algo para la próxima vez")
    }

    /// By reply id, the lessons Alice kept after it: the last reply of the turn the lesson came in
    /// (learned while answering, it is written seconds before that reply ends), or of the turn before it
    /// (a review once the chat paused). Any profile: Hermes serves them all in one process, and whichever
    /// passes first applies the shared queue (an Alice lesson was once logged as Inbox's).
    static func replies(in messages: [Message], actions: [AgentAction]) -> [String: [AgentAction]] {
        let shown = messages
            .filter { MessageTime.isKnown($0.createdAt) && !$0.pending
                && ($0.role == .user || ($0.role == .assistant && !$0.content.isEmpty)) }
            .sorted { $0.createdAt < $1.createdAt }
        var result: [String: [AgentAction]] = [:]
        for action in actions where action.kind == "skill.learned" {
            // The turn: from the person's last message before the lesson to their next one.
            let asked = shown.last { $0.role == .user && $0.createdAt <= action.at }?.createdAt ?? .distantPast
            let next = shown.first { $0.role == .user && $0.createdAt > asked && $0.createdAt > action.at }?.createdAt
                ?? .distantFuture
            guard let reply = shown.last(where: {
                $0.role == .assistant && $0.createdAt >= asked && $0.createdAt < next
            }), abs(action.at.timeIntervalSince(reply.createdAt)) <= window else { continue }
            result[reply.id, default: []].append(action)
        }
        return result
    }
}
