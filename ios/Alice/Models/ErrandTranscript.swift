import Foundation

/// One errand has one place in the whole transcript, even when several replies
/// refer to it. Resolve before taking the visible window so scrolling cannot
/// move an old errand onto a newer reply.
enum ErrandTranscript {
    static func placements(
        messages: [Message], errands: [Errand], session: String?
    ) -> [String: [ErrandRef]] {
        var result: [String: [ErrandRef]] = [:]
        var seen = Set<String>()
        let ordered = errands.sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
        }
        for errand in ordered where seen.insert(errand.id).inserted {
            let explicit = messages.indices.first { index in
                let message = messages[index]
                return canHost(message) && message.tools.contains { call in
                    ErrandRef.isTool(call.name) && ErrandRef.parse(call.detail)?.errandID == errand.id
                }
            }
            // The plugin can start an errand before the model calls its tool.
            // Time is corroboration only: the actual request and session must
            // match. A two-minute clock allowance alone linked old messages.
            var inferred: Int?
            if let session, !session.isEmpty, errand.originSession == session {
                let request = normalized(errand.request)
                let candidates = messages.indices.filter {
                    messages[$0].role == .user && !request.isEmpty
                        && normalized(messages[$0].content) == request
                        && abs(messages[$0].createdAt.timeIntervalSince(errand.startedAt)) <= 120
                }
                let before = candidates.last { messages[$0].createdAt <= errand.startedAt }
                if let asked = before ?? candidates.first {
                    let end = messages.indices.first { $0 > asked && messages[$0].role == .user }
                        ?? messages.endIndex
                    inferred = ((asked + 1)..<end).first { canHost(messages[$0]) }
                }
            }
            guard let owner = [explicit, inferred].compactMap({ $0 }).min() else { continue }
            result[messages[owner].id, default: []].append(
                ErrandRef(errandID: errand.id, title: errand.title)
            )
        }
        return result
    }

    private static func canHost(_ message: Message) -> Bool {
        message.role == .assistant && (!message.pending || !message.content.isEmpty)
            && message.routineName == nil && message.routineGroup == nil
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
