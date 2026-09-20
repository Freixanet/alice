import Foundation

/// The name a chat gets in the drawer, taken from what was actually asked.
///
/// The first forty characters of the first message made titles like "hola,
/// una cosa: quería que me ayudaras con" — true to the keystrokes, not to the
/// subject. This keeps the subject: the lead-in and the greeting go, an
/// `@agent` becomes its name (the `@` is only how the composer opens the
/// list), a bare address becomes its site, and the cut lands on a word, not
/// mid-word. A message that is only a greeting names nothing, so the chat
/// stays "New chat" until a real one arrives.
enum ConversationTitle {
    static let placeholder = "New chat"
    static let maxLength = 40

    /// A title for `text`, or nil when it says nothing worth a title yet.
    static func from(_ text: String, attachmentName: String? = nil) -> String? {
        var line = firstMeaningfulLine(text)
        line = replaceAddresses(in: line)
        line = stripMarkdown(line)
        line = stripLeadIn(line)
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?¡¿-–—\"'«»“” "))
        if isNoise(line) {
            guard let attachmentName, !attachmentName.isEmpty else { return nil }
            return clipped(attachmentName)
        }
        return clipped(capitalized(line))
    }

    /// Whether `title` is still the placeholder and can be replaced.
    static func isPlaceholder(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty || title == placeholder
    }

    /// Ranges in a drawer title that name an invoked agent, longest first so
    /// "Mi Inbox" is not taken as "Mi". `@` is accepted if an older title
    /// still has it; the drawer shows the name without it.
    static func agentNameRanges(
        in title: String, names: [(display: String, slug: String)]
    ) -> [(Range<String.Index>, String)] {
        let ordered = names
            .filter { !$0.display.isEmpty }
            .sorted { $0.display.count > $1.display.count }
        var taken: [Range<String.Index>] = []
        var found: [(Range<String.Index>, String)] = []

        for (display, slug) in ordered {
            for needle in ["@" + display, display] {
                var from = title.startIndex
                while let range = title.range(
                    of: needle, options: .caseInsensitive, range: from..<title.endIndex
                ) {
                    from = range.upperBound
                    guard isWord(range, in: title),
                          !taken.contains(where: { $0.overlaps(range) })
                    else { continue }
                    taken.append(range)
                    found.append((range, slug))
                }
            }
        }
        return found
    }

    /// Drops `@` in front of an invoked agent so the drawer can show the name
    /// in that agent's colour and nothing else.
    static func strippingAtMentions(
        in title: String, invoked names: [(display: String, slug: String)]
    ) -> String {
        var result = title
        let ordered = names
            .filter { !$0.display.isEmpty }
            .sorted { $0.display.count > $1.display.count }
        for (display, _) in ordered {
            while let range = firstWord(of: "@" + display, in: result) {
                result.replaceSubrange(range, with: result[result.index(after: range.lowerBound)..<range.upperBound])
            }
        }
        return result
    }

    static func isWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let startsWord = range.lowerBound == text.startIndex
            || text[text.index(before: range.lowerBound)].isWhitespace
        let endsWord = range.upperBound == text.endIndex
            || !(text[range.upperBound].isLetter || text[range.upperBound].isNumber
                 || text[range.upperBound] == "-" || text[range.upperBound] == "_")
        return startsWord && endsWord
    }

    static func firstWord(of needle: String, in title: String) -> Range<String.Index>? {
        var from = title.startIndex
        while let range = title.range(
            of: needle, options: .caseInsensitive, range: from..<title.endIndex
        ) {
            from = range.upperBound
            if isWord(range, in: title) { return range }
        }
        return nil
    }

    // MARK: Pieces

    private static func firstMeaningfulLine(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        // The first line that is more than a greeting; else the first line.
        for line in lines where !isNoise(stripLeadIn(replaceAddresses(in: line))) {
            return line
        }
        return lines.first ?? ""
    }

    /// `@descargas https://youtube.com/…` → `descargas youtube.com`.
    private static func replaceAddresses(in line: String) -> String {
        var out = line
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = out as NSString
            for match in detector.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                var host = (url.host ?? "").lowercased()
                if host.hasPrefix("www.") { host.removeFirst(4) }
                out = (out as NSString).replacingCharacters(in: match.range, with: host)
            }
        }
        // `@` only opens the composer menu; the title keeps the name.
        out = out.replacingOccurrences(of: #"(^|\s)@([\w\-\.]+)"#, with: "$1$2", options: .regularExpression)
        return out
    }

    private static func stripMarkdown(_ line: String) -> String {
        var out = line
        for token in ["**", "__", "`", "~~", "#"] { out = out.replacingOccurrences(of: token, with: "") }
        out = out.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
        return out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// Openers that carry no subject, in the languages the app is used in.
    private static let leadIns: [String] = [
        "hola", "hola,", "hey", "hey,", "hi", "hi,", "hello", "hello,", "buenas", "buenas,", "buenos días",
        "buenas tardes", "buenas noches", "oye", "oye,", "mira", "mira,", "por favor", "porfa", "please",
        "una cosa", "una pregunta", "tengo una pregunta", "tengo una duda", "quería preguntarte",
        "quiero que", "quería que", "necesito que", "puedes", "podrías", "me puedes", "me podrías",
        "me ayudaras con", "me ayudaras a", "me ayudes con", "me ayudes a", "ayudarme con", "ayudarme a",
        "me ayudes", "me ayudaras", "me ayudara",
        "ayúdame a", "ayudame a", "ayúdame con", "ayudame con", "quiero", "quería", "necesito", "dime", "explícame",
        "can you", "could you", "i want you to", "i need you to", "i want to", "i need to", "help me",
        "i'd like to", "i would like to", "please help me", "tell me", "explain",
    ]

    private static let leadInsLongestFirst = leadIns.sorted { $0.count > $1.count }

    private static func stripLeadIn(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            let lowered = text.lowercased()
            for lead in leadInsLongestFirst where lowered.hasPrefix(lead) {
                let after = text.dropFirst(lead.count)
                guard after.isEmpty || after.first == " " || after.first == "," || after.first == ":" else { continue }
                text = after.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
                changed = true
                break
            }
        }
        return text
    }

    private static let noiseWords: Set<String> = [
        "hola", "hey", "hi", "hello", "buenas", "gracias", "thanks", "ok", "vale", "sí", "si", "no",
        "test", "prueba", "hola?", "?", "..", "...",
    ]

    private static func isNoise(_ line: String) -> Bool {
        let cleaned = line.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?¡¿-–—\"'«»“” "))
        if cleaned.isEmpty { return true }
        let words = cleaned.split(separator: " ")
        if words.allSatisfy({ noiseWords.contains(String($0)) }) { return true }
        // Nothing but symbols or a single letter: not a subject.
        return cleaned.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) } || cleaned.count < 2
    }

    private static func capitalized(_ line: String) -> String {
        guard let first = line.first else { return line }
        return String(first).uppercased() + line.dropFirst()
    }

    /// At most `maxLength` characters, cut on a word with an ellipsis when
    /// something is left out.
    static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let head = String(trimmed.prefix(maxLength - 1))
        let punctuation = CharacterSet(charactersIn: ".,;:!?¡¿-–— ")
        // The cut already lands on a word: the next character is a space.
        let next = trimmed[trimmed.index(trimmed.startIndex, offsetBy: maxLength - 1)]
        if next == " " { return head.trimmingCharacters(in: punctuation) + "…" }
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= maxLength / 2 {
            return String(head[..<space]).trimmingCharacters(in: punctuation) + "…"
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }
}
