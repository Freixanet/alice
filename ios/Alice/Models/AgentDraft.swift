import Foundation

/// A new agent, from a sentence rather than a form.
///
/// Alice mints the Hermes profile now, opens that agent's own chat, and lets
/// it ask whatever is still open. The display name has to be short enough to
/// live on the Agents page; the standing instructions keep the brief intact.
enum AgentDraft {
    /// A short display name from a free-form brief. Empty when there is
    /// nothing that could be a name.
    static func name(from brief: String) -> String {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return headline(from: firstLine)
    }

    /// Standing instructions for a profile that only has a brief so far.
    static func soul(from brief: String) -> String {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        # Role

        \(trimmed)

        Write in short paragraphs. One idea at a time. Do not pad, and do not break every sentence onto its own line.

        On first contact, greet in one short sentence as this role. Then ask only what you still need to do the job well — delivery, language, cadence, sources, limits — each with a recommended default. Do not wait for them to repeat the brief.

        ## Examples

        Person: \(trimmed)
        You: Here is what I can do with that. If I need a source or a missing fact, I say so instead of inventing it.

        Person: Make something up if you do not know.
        You: No. If I do not have it, I say so.
        """
    }

    /// Two-word headline, title-cased. Drops the lead-in ("I want an agent
    /// that…") and the opening verb ("watch", "track") so the Agents page
    /// shows a name rather than the first five words of a sentence.
    static func headline(from line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'«»"))
        guard !text.isEmpty else { return "" }
        let stripped = stripLeadIn(text)
        let afterVerb = stripLeadingVerb(stripped)
        let clause = cutClause(afterVerb)
        let words = contentWords(clause)
        let picked = Array(words.prefix(2))
        let source = picked.isEmpty ? Array(contentWords(text).prefix(2)) : picked
        guard !source.isEmpty else {
            return String(text.prefix(28)).trimmingCharacters(in: .whitespaces)
        }
        var title = source.map(titleCase).joined(separator: " ")
        if title.count > 28 {
            title = String(title.prefix(28)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    private static let leadIns = [
        "i want an agent that", "i need an agent that",
        "create an agent that", "make an agent that",
        "quiero un agente que", "necesito un agente que",
        "an agent that", "an agent to", "un agente que", "un agente para",
        "i want you to", "i need you to",
        "i want", "i need", "quiero", "necesito",
        "help me", "ayúdame", "ayudame", "please", "por favor",
    ]

    private static let verbs: Set<String> = [
        "watch", "track", "monitor", "follow", "summarize", "summarise",
        "resume", "tell", "make", "write", "find", "search", "check",
        "get", "give", "show", "send", "collect", "scan", "report",
        "review", "analyse", "analyze", "keep", "alert", "notify",
        "look", "create", "haz", "busca", "sigue", "vigila", "rastrea",
        "revisa", "escribe", "muestra", "encuentra", "crea",
    ]

    private static let stop: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "for", "in", "on", "at",
        "me", "my", "what", "this", "it", "its", "actually", "really", "just",
        "please", "about", "with", "from", "into", "over", "every", "each",
        "how", "as", "if", "do", "does", "did", "be", "is", "are", "that",
        "el", "la", "los", "las", "un", "una", "de", "del", "que", "y", "o",
        "en", "por", "para", "con", "mi", "lo", "al", "se", "su", "tu",
        "tus", "cada", "todo", "todos", "todas",
    ]

    private static func stripLeadIn(_ text: String) -> String {
        let lower = text.lowercased()
        for prefix in leadIns {
            if lower.hasPrefix(prefix) {
                let index = text.index(text.startIndex, offsetBy: prefix.count)
                return text[index...].trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    private static func stripLeadingVerb(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, verbs.contains(first.lowercased()) else { return text }
        words.removeFirst()
        if words.first?.lowercased() == "me" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    private static func cutClause(_ text: String) -> String {
        let cuts = [" and ", " y ", " then ", " luego ", ","]
        var end = text.endIndex
        for cut in cuts {
            if let range = text.range(of: cut, options: .caseInsensitive),
               range.lowerBound < end {
                end = range.lowerBound
            }
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func contentWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?\"'«»")) }
            .filter { !$0.isEmpty && !stop.contains($0.lowercased()) }
    }

    private static func titleCase(_ word: String) -> String {
        if word.count >= 2 && word == word.uppercased() { return word }
        return word.localizedCapitalized
    }
}
