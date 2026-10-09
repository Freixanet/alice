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
                // Started by the plugin with no tap (the one option asked for, 07-10): under the
                // request it answered, the last thing the person said in this chat before it.
                let asked = choices.isEmpty && errand.originSession == session
                    ? messages.indices.last(where: {
                        messages[$0].role == .user && messages[$0].createdAt <= errand.startedAt
                            && errand.startedAt.timeIntervalSince(messages[$0].createdAt) <= 1800
                    })
                    : nil
                if let owner = choices.last(where: { messages[$0].createdAt <= errand.startedAt }) ?? choices.first ?? asked {
                    // The reply to the choice («La estoy preparando…») reads first, then the errand:
                    // shown before it, the reply landed above a card already on screen.
                    let replied = messages[(owner + 1)...].contains { canHost($0) }
                    if !replied, now.timeIntervalSince(errand.startedAt) < replyWait { continue }
                    let at = latest(from: owner, until: until(errand), in: messages)
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
            result[messages[latest(from: owner, until: until(errand), in: messages)].id, default: []].append(
                ErrandRef(errandID: errand.id, title: errand.title)
            )
        }
        return result
    }

    /// How long a chosen purchase's card waits for the reply to the choice before showing anyway.
    static let replyWait: TimeInterval = 15

    /// A running errand is the live thing in the chat and stays last, its browser and cards where
    /// the person is reading; a finished one stays after the last turn before it ended. A message's
    /// time is when its turn began, not when it appeared, so ordering a running errand by time put
    /// its browser above replies already on screen.
    private static func until(_ errand: Errand) -> Date {
        errand.status.isOpen ? .distantFuture : errand.updatedAt
    }

    /// The chat reads in the order things happened: an errand's block sits after the last turn
    /// written before its latest change, not under the turn that started it. Anchored there, a
    /// browser, a summary or a stop showed up above turns written after them.
    static func latest(from owner: Int, until moment: Date, in messages: [Message]) -> Int {
        var at = owner
        var index = owner + 1
        while index < messages.count, messages[index].createdAt <= moment {
            if messages[index].role == .user || canHost(messages[index]) { at = index }
            index += 1
        }
        return at
    }

    private static func canHost(_ message: Message) -> Bool {
        message.role == .assistant && (!message.pending || !message.content.isEmpty)
            && message.routineName == nil && message.routineGroup == nil
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
