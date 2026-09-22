import Foundation

/// A past conversation an agent cited as the source of what it said.
///
/// Hermes' `session_search` gives the agent a `link` for every conversation it
/// finds — `@session:<profile>/<session id>` — and tells it to write that in
/// the sentence, where Hermes' own apps draw it as a titled link. The Alice
/// style guide asks for the cited message as well: `#<message id>`. Alice
/// draws the token as a link titled with the conversation's name, and lists
/// the sources under the reply; tapping either opens the turns around the
/// cited message (`ReceiptSheet`).
struct RichReceipt: Equatable, Hashable, Sendable, Identifiable {
    /// Nil when the agent could not name the profile: the chat's own agent.
    var profile: String?
    var session: String
    /// Hermes' id for the cited message, when the agent gave it.
    var message: Int?
    /// The moment to open at instead, for an action in Activity.
    var at: Date?

    var id: String { "\(profile ?? "")/\(session)#\(message.map(String.init) ?? "")@\(at?.timeIntervalSince1970 ?? 0)" }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = "alice"
        parts.host = "receipt"
        var items = [URLQueryItem(name: "session", value: session)]
        if let profile { items.append(URLQueryItem(name: "profile", value: profile)) }
        if let message { items.append(URLQueryItem(name: "m", value: String(message))) }
        parts.queryItems = items
        return parts.url!
    }

    init(profile: String?, session: String, message: Int? = nil, at: Date? = nil) {
        self.profile = profile
        self.session = session
        self.message = message
        self.at = at
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "alice", url.host?.lowercased() == "receipt",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let session = items.first(where: { $0.name == "session" })?.value,
              Receipts.isSessionID(session)
        else { return nil }
        let profile = items.first { $0.name == "profile" }?.value
        self.init(
            profile: profile.flatMap { Receipts.isProfile($0) ? $0 : nil },
            session: session,
            message: items.first { $0.name == "m" }?.value.flatMap(Int.init)
        )
    }
}

enum Receipts {
    /// `@session:perfil/id#123`, the profile and the message optional. Models
    /// sometimes wrap it in backticks despite being told not to.
    private static let token = try! NSRegularExpression(
        pattern: #"`?@session:(?:([a-z0-9][a-z0-9_-]{0,63})/)?([A-Za-z0-9][A-Za-z0-9_-]{5,127})(?:#(\d{1,12}))?`?"#
    )

    static func isSessionID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{5,127}$"#, options: .regularExpression) != nil
    }

    static func isProfile(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// The conversations a reply cites, in order, each once.
    static func cited(in text: String) -> [RichReceipt] {
        guard text.contains("@session:") else { return [] }
        var seen: Set<RichReceipt> = []
        return matches(in: text).map(\.receipt).filter { seen.insert($0).inserted }
    }

    private static func matches(in text: String) -> [(range: Range<String.Index>, receipt: RichReceipt)] {
        token.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let session = Range(match.range(at: 2), in: text)
            else { return nil }
            let profile = Range(match.range(at: 1), in: text).map { String(text[$0]) }
            let message = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) }
            return (whole, RichReceipt(profile: profile, session: String(text[session]), message: message))
        }
    }

    /// The reply with each token as a link titled with its conversation.
    ///
    /// Untitled until the title is known — "that conversation" — and redrawn
    /// when it arrives. Tokens inside code stay as written.
    static func titled(_ text: String, titles: [String: String], language: ChatLanguage) -> String {
        guard text.contains("@session:") else { return text }
        var output = ""
        var cursor = text.startIndex
        let fences = codeRanges(in: text)
        for (range, receipt) in matches(in: text) {
            if fences.contains(where: { $0.overlaps(range) }) { continue }
            output += text[cursor..<range.lowerBound]
            let title = titles[receipt.session].flatMap { $0.isEmpty ? nil : $0 }
                ?? language.pick("that conversation", "esa conversación")
            let safe = title.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            output += "[\(safe)](\(receipt.url.absoluteString))"
            cursor = range.upperBound
        }
        output += text[cursor...]
        return output
    }

    /// Receipts already turned into links, for the sources under the reply.
    static func linked(in text: String) -> [RichReceipt] {
        guard text.contains("alice://receipt") else { return [] }
        let pattern = #"\]\((alice://receipt\?[^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen: Set<RichReceipt> = []
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { URL(string: String(text[$0])) }.flatMap(RichReceipt.init(url:))
        }.filter { seen.insert($0).inserted }
    }

    private static func codeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var search = text.startIndex
        while let open = text.range(of: "```", range: search..<text.endIndex) {
            guard let close = text.range(of: "```", range: open.upperBound..<text.endIndex) else {
                ranges.append(open.lowerBound..<text.endIndex)
                break
            }
            ranges.append(open.lowerBound..<close.upperBound)
            search = close.upperBound
        }
        return ranges
    }
}

/// A few turns of a past conversation, as the Alice plugin serves them.
struct ConversationReceipt: Equatable, Sendable {
    struct Turn: Equatable, Sendable, Identifiable {
        let id: String
        let role: Message.Role
        let text: String
        let at: Date?
        /// The message the agent cited, or the moment an action happened.
        let anchor: Bool
    }

    let profile: String
    let session: String
    let title: String
    let started: Date?
    /// A routine's run, by its `profile/job id`, when that is what it was.
    let routineKey: String?
    let routineName: String?
    let turns: [Turn]

    static func parse(_ object: [String: Any]) -> ConversationReceipt? {
        guard let session = object["session"] as? String else { return nil }
        let origin = object["origin"] as? [String: Any]
        let isRoutine = (origin?["place"] as? String) == "routine"
        let turns = ((object["messages"] as? [[String: Any]]) ?? []).compactMap { row -> Turn? in
            guard let text = row["text"] as? String, !text.isEmpty,
                  let role = (row["role"] as? String).flatMap(Message.Role.init(rawValue:))
            else { return nil }
            return Turn(
                id: (row["id"] as? String) ?? UUID().uuidString, role: role, text: text,
                at: (row["at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                anchor: (row["anchor"] as? Bool) ?? false
            )
        }
        return ConversationReceipt(
            profile: (object["profile"] as? String) ?? "default",
            session: session,
            title: (object["title"] as? String) ?? "",
            started: (object["started_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
            routineKey: isRoutine ? origin?["routine"] as? String : nil,
            routineName: isRoutine ? (origin?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil,
            turns: turns
        )
    }

    /// The name to show: the routine's, the conversation's, or the chat with
    /// its agent — an agent's lasting chat is titled "Bot Chat" in Hermes.
    func displayTitle(agent: String) -> String {
        ConversationReceipt.displayTitle(title, routine: routineName, agent: agent)
    }

    static func displayTitle(_ title: String, routine: String?, agent: String) -> String {
        if let routine { return routine }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "Bot Chat" ? String(localized: "Chat with \(agent)") : trimmed
    }
}
