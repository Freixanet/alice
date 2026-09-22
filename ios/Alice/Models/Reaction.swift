import Foundation

/// A yes or a no to what a reply proposed, given with one tap.
///
/// Sent as an ordinary turn so the agent reads it as his answer and Hermes
/// keeps it in the transcript, which is also where the phone reads it back
/// from: no second record to fall out of step. The turn is a thumb on its own,
/// or a quoted line from an older reply and then the thumb, which is how a
/// model already reads "that one: yes". A line in brackets under it says what
/// the phone did with the reply's card, so the agent does not do it twice.
///
///     > Te propongo mover la cena al viernes…
///     👍
///     (añadido al calendario)
enum Reaction: String, CaseIterable, Sendable {
    case yes = "👍"
    case no = "👎"

    var symbol: String { self == .yes ? "hand.thumbsup" : "hand.thumbsdown" }

    /// What it means, for VoiceOver and for the one-line confirmation.
    func meaning(in language: ChatLanguage) -> String {
        self == .yes ? language.pick("Yes", "Sí") : language.pick("No", "No")
    }
}

struct ReactionTurn: Equatable, Sendable {
    var reaction: Reaction
    /// The start of the reply it answers, when that was not the latest one.
    var quote: String?
    /// What the phone already did about it — "añadido al calendario".
    var note: String?

    static let quoteLength = 90

    /// The turn as Hermes stores it.
    var text: String {
        var lines: [String] = []
        if let quote, !quote.isEmpty { lines.append("> " + quote) }
        lines.append(reaction.rawValue)
        if let note, !note.isEmpty { lines.append("(\(note))") }
        return lines.joined(separator: "\n")
    }

    /// Reads a turn back, whoever wrote it. A thumb typed on its own is the
    /// same answer as one tapped, and draws the same way. A leading `@agent`
    /// is how a reply to an agent asked by name is addressed; it is not part
    /// of the answer.
    static func parse(_ content: String) -> ReactionTurn? {
        var lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 3 else { return nil }
        if lines[0].hasPrefix("@"), let space = lines[0].firstIndex(of: " ") {
            lines[0] = String(lines[0][lines[0].index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        var quote: String?
        if lines[0].hasPrefix(">") {
            quote = String(lines.removeFirst().dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let first = lines.first, let reaction = Self.reaction(first) else { return nil }
        lines.removeFirst()
        var note: String?
        if let last = lines.first {
            guard last.hasPrefix("("), last.hasSuffix(")"), lines.count == 1 else { return nil }
            note = String(last.dropFirst().dropLast())
        }
        return ReactionTurn(reaction: reaction, quote: quote, note: note)
    }

    /// A thumb, with or without a skin tone.
    private static func reaction(_ line: String) -> Reaction? {
        let base = String(line.unicodeScalars.filter {
            !(0x1F3FB...0x1F3FF).contains($0.value) && $0.value != 0xFE0F
        }.map(Character.init))
        return Reaction(rawValue: base)
    }

    /// The first words of a reply, as plain text, to quote it.
    static func snippet(of content: String) -> String {
        var text = content
        // Cards and code are not words anyone would quote.
        while let open = text.range(of: "```") {
            let rest = text[open.upperBound...]
            guard let close = rest.range(of: "```") else {
                text = String(text[..<open.lowerBound])
                break
            }
            text = String(text[..<open.lowerBound]) + " " + String(rest[close.upperBound...])
        }
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"@session:\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`#>|]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[!\w+\]"#, with: "", options: .regularExpression)
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > quoteLength else { return words }
        let cut = words.prefix(quoteLength)
        let clean = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return clean.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// Whether a reply is the one this quote was taken from.
    static func matches(_ quote: String, _ content: String) -> Bool {
        let quoted = quote.hasSuffix("…") ? String(quote.dropLast()) : quote
        return !quoted.isEmpty && snippet(of: content).hasPrefix(quoted)
    }
}

/// Who answered what, read off the transcript.
enum Reactions {
    /// The reply each reaction in `messages` answers, by message id.
    ///
    /// A bare thumb answers the reply right before it. A quoted one answers
    /// the latest earlier reply that starts with the quote; one whose reply is
    /// no longer on the phone answers nothing here.
    static func given(in messages: [Message]) -> [String: Reaction] {
        var found: [String: Reaction] = [:]
        for (index, message) in messages.enumerated() where message.role == .user {
            guard let turn = ReactionTurn.parse(message.content),
                  let target = target(of: turn, before: index, in: messages)
            else { continue }
            found[target] = turn.reaction
        }
        return found
    }

    /// Messages whose offers a reaction has closed: a no closes the reply it
    /// answers, as «No, gracias» would.
    static func declined(in messages: [Message]) -> Set<String> {
        Set(given(in: messages).filter { $0.value == .no }.map(\.key))
    }

    static func target(of turn: ReactionTurn, before index: Int, in messages: [Message]) -> String? {
        let earlier = messages[..<index].reversed().filter { $0.role == .assistant && !$0.content.isEmpty }
        guard let quote = turn.quote else { return earlier.first?.id }
        return earlier.first { ReactionTurn.matches(quote, $0.content) }?.id
    }

    /// Whether a reply asks or offers something a yes or a no answers: a
    /// question at its end, reply buttons, or a calendar card.
    static func invites(_ message: Message) -> Bool {
        guard message.role == .assistant, !message.pending, !message.content.isEmpty else { return false }
        let content = message.content
        if content.contains("alice://reply") || content.contains("alice://calendar/") { return true }
        let lastLine = content.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lastLine.map { $0.contains("?") } ?? false
    }

    /// Whether this turn is a reaction. A reaction answers one reply; unlike
    /// anything he writes, it does not pass over the others' offers.
    static func isReaction(_ message: Message) -> Bool {
        message.role == .user && ReactionTurn.parse(message.content) != nil
    }
}
