import Foundation

/// A reply to one of Alice's messages: swiped right in the chat, it rides at the top of the next
/// message as a Markdown quote, so the model reads what is being answered and the chat, reloaded
/// from Hermes later, still shows it.
struct ReplyQuote: Hashable, Sendable {
    let messageID: String
    /// Who wrote it, as the composer names them: «Replying to Alice».
    let author: String
    let excerpt: String

    static let excerptLimit = 280

    init(messageID: String, author: String, content: String) {
        self.messageID = messageID
        self.author = author
        excerpt = Self.excerpt(content)
    }

    /// The reply's words on one line, cut at a word near the limit.
    static func excerpt(_ content: String) -> String {
        let flat = content
            .replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > excerptLimit else { return flat }
        let cut = flat.prefix(excerptLimit)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word + "…"
    }

    /// What goes before the person's own words.
    var prefix: String { "> \(excerpt)\n\n" }

    /// A sent message's quote and its own words, when it starts with one.
    static func split(_ content: String) -> (quote: String, text: String)? {
        guard content.hasPrefix("> "), let gap = content.range(of: "\n\n") else { return nil }
        let quote = content[..<gap.lowerBound]
            .split(separator: "\n")
            .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: " ")
        let text = String(content[gap.upperBound...])
        guard !quote.isEmpty, !text.isEmpty else { return nil }
        return (quote, text)
    }

    /// Mention ranges of a sent message, moved onto its own words when a quote goes before them.
    static func ranges(_ ranges: [NSRange], in content: String) -> [NSRange] {
        guard let text = split(content)?.text else { return ranges }
        let shift = content.utf16.count - text.utf16.count
        return ranges.compactMap { $0.location >= shift ? NSRange(location: $0.location - shift, length: $0.length) : nil }
    }
}
