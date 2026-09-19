import Foundation

/// The name a chat gets in the drawer, taken from what was actually asked.
///
/// The first forty characters of the first message made titles like "hola,
/// una cosa: quería que me ayudaras con" — true to the keystrokes, not to the
/// subject. This keeps the subject: the lead-in and the greeting go, an
/// `@agent` becomes its name, a bare address becomes its site, and the cut
/// lands on a word, not mid-word. A message that is only a greeting names
/// nothing, so the chat stays "New chat" until a real one arrives.
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
        // An @mention is who was asked; keep the name, drop the sign.
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
