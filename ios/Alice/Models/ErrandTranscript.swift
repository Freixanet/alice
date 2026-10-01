import Foundation

/// One errand has one place in the whole transcript, even when several replies
/// refer to it. Resolve before taking the visible window so scrolling cannot
/// move an old errand onto a newer reply.
enum ErrandTranscript {
    static func placements(
        messages: [Message], errands: [Errand], session: String?, now: Date = .now
    ) -> [String: [ErrandRef]] {
        var result: [String: [ErrandRef]] = [:]
        var explicit: [String: Int] = [:]
        var requests: [String: [Int]] = [:]
        var firstReplies: [Int: Int] = [:]
        var asked: Int?
        // Parse each tool only once; this projection also runs as chat tokens arrive.
        for index in messages.indices {
            let message = messages[index]
            if message.role == .user {
                asked = index
                requests[normalized(message.content), default: []].append(index)
            } else if canHost(message) {
                if let asked, firstReplies[asked] == nil { firstReplies[asked] = index }
                for call in message.tools where ErrandRef.isTool(call.name) {
                    if let id = ErrandRef.parse(call.detail)?.errandID, explicit[id] == nil {
                        explicit[id] = index
                    }
                }
            }
        }
        var seen = Set<String>()
        let ordered = errands.sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
        }
        for errand in ordered where seen.insert(errand.id).inserted {
            // A tapped purchase belongs immediately under that choice, even before a reply arrives.
            // Match the session and option, then time, so a repeated purchase keeps its own turn.
            if let option = errand.optionID {
                let choices = messages.indices.filter {
                    messages[$0].role == .user && PurchaseChoice.id(in: messages[$0].content) == option
                        && (messages[$0].mentionSessionID ?? session) == errand.originSession
                        && abs(messages[$0].createdAt.timeIntervalSince(errand.startedAt)) <= 120
                }
                if let owner = choices.last(where: { messages[$0].createdAt <= errand.startedAt }) ?? choices.first {
                    // The reply to the choice («La estoy preparando…») reads first, then the errand:
                    // shown before it, the reply landed above a card already on screen.
                    let reply = messages.indices.dropFirst(owner + 1).prefix(while: { messages[$0].role != .user }).first { canHost(messages[$0]) }
                    guard let reply else { continue }
                    let at = reply
                    result[messages[at].id, default: []].append(ErrandRef(errandID: errand.id, title: errand.title))
                    continue
                }
            }
            // The plugin can start an errand before the model calls its tool.
            // Time is corroboration only: the actual request and session must
            // match. A two-minute clock allowance alone linked old messages.
            var inferred: Int?
            if let session, !session.isEmpty, errand.originSession == session {
                let request = normalized(errand.request)
                let candidates = (request.isEmpty ? [] : requests[request] ?? []).filter {
                    abs(messages[$0].createdAt.timeIntervalSince(errand.startedAt)) <= 120
                }
                let before = candidates.last { messages[$0].createdAt <= errand.startedAt }
                if let asked = before ?? candidates.first {
                    inferred = firstReplies[asked]
                }
            }
            guard let owner = [explicit[errand.id], inferred].compactMap({ $0 }).min() else { continue }
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
