import Foundation

/// A routine from one sentence: "cada mañana a las 8 dime el tiempo en Blanes".
///
/// A person does not think in cron. They say when and what in the same
/// breath, so the sentence is read for the *when* — a time of day, days of
/// the week, an interval — and the rest is the *what*. What is found fills
/// the schedule controls, so it can still be checked and changed by hand;
/// nothing is sent to Hermes that the person has not seen.
enum RoutineBrief {
    enum Cadence: Equatable {
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)
        case weekly(days: [Int], hour: Int, minute: Int)      // 1 = Monday … 7 = Sunday
        case interval(value: Int, unit: String)               // "m", "h", "d"
    }

    struct Reading: Equatable {
        var cadence: Cadence?
        /// The sentence without the part that said when.
        var task: String
        /// A short name for the routine list.
        var name: String
    }

    /// Hermes' own schedule words for a cadence Alice found.
    static func schedule(for cadence: Cadence) -> String {
        switch cadence {
        case let .daily(hour, minute):
            return "every day at \(clock(hour, minute))"
        case let .weekdays(hour, minute):
            return "weekdays at \(clock(hour, minute))"
        case let .weekly(days, hour, minute):
            let names = days.sorted().map { dayNames[$0 - 1] }
            return "every \(names.joined(separator: ",")) at \(clock(hour, minute))"
        case let .interval(value, unit):
            return "every \(value)\(unit)"
        }
    }

    /// The cadence, said back so the person can check it.
    static func describe(_ cadence: Cadence) -> String {
        switch cadence {
        case let .daily(hour, minute):
            return "Every day at \(clock(hour, minute))"
        case let .weekdays(hour, minute):
            return "Monday to Friday at \(clock(hour, minute))"
        case let .weekly(days, hour, minute):
            let names = days.sorted().map { dayLongNames[$0 - 1] }
            return "Every \(names.joined(separator: ", ")) at \(clock(hour, minute))"
        case let .interval(value, unit):
            let word: String
            switch unit {
            case "m": word = value == 1 ? "minute" : "minutes"
            case "d": word = value == 1 ? "day" : "days"
            default: word = value == 1 ? "hour" : "hours"
            }
            return "Every \(value) \(word)"
        }
    }

    static func read(_ text: String) -> Reading {
        var sentence = " " + text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression) + " "
        var cadence: Cadence?

        // Interval: "cada 2 horas", "every 30 minutes", "every hour".
        if let match = firstMatch(#"(?i)\b(cada|every)\s+(\d+)?\s*(minutos?|minutes?|mins?|horas?|hours?|hrs?|d[ií]as?|days?)\b"#, in: sentence) {
            let value = Int(match.groups[2]) ?? 1
            let unit = match.groups[3].lowercased()
            let code = unit.hasPrefix("min") ? "m" : (unit.hasPrefix("d") ? "d" : "h")
            cadence = .interval(value: max(1, value), unit: code)
            sentence = sentence.replacingCharacters(in: match.range, with: " ")
        }

        // Time of day: "a las 8", "a las 8:30", "at 9am", "at 18:00", "a las 8 de la mañana".
        var hour = 9, minute = 0, foundTime = false
        if let match = firstMatch(#"(?i)\b(a\s+las?|at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|h)?(\s+de\s+la\s+(mañana|tarde|noche))?\b"#, in: sentence) {
            hour = Int(match.groups[2]) ?? 9
            minute = Int(match.groups[3]) ?? 0
            let suffix = match.groups[4].lowercased()
            let part = match.groups[6].lowercased()
            if suffix == "pm" || part == "tarde" || part == "noche", hour < 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
            if (0...23).contains(hour), (0...59).contains(minute) {
                foundTime = true
                sentence = sentence.replacingCharacters(in: match.range, with: " ")
            }
        }

        // Days: weekdays, a named day or several, "cada día", "todas las mañanas".
        if cadence == nil {
            if let match = firstMatch(#"(?i)\b(entre\s+semana|d[ií]as?\s+laborables?|de\s+lunes\s+a\s+viernes|on\s+weekdays|weekdays|every\s+weekday)\b"#, in: sentence) {
                cadence = .weekdays(hour: hour, minute: minute)
                sentence = sentence.replacingCharacters(in: match.range, with: " ")
            } else {
                var days: [Int] = []
                var scan = sentence
                while let match = firstMatch(#"(?i)\b(?:cada|los|todos\s+los|every|on|each)?\s*(lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bados?|domingos?|mondays?|tuesdays?|wednesdays?|thursdays?|fridays?|saturdays?|sundays?)\b"#, in: scan) {
                    if let day = dayNumber(match.groups[1]) { days.append(day) }
                    scan = scan.replacingCharacters(in: match.range, with: " ")
                }
                if !days.isEmpty {
                    cadence = .weekly(days: Array(Set(days)), hour: hour, minute: minute)
                    sentence = scan.replacingOccurrences(of: #"(?i)\s+(y|and|,)\s+(?=\s)"#, with: " ", options: .regularExpression)
                } else if let match = firstMatch(#"(?i)\b(cada\s+(d[ií]a|mañana|tarde|noche)|todos\s+los\s+d[ií]as|todas\s+las\s+(mañanas|tardes|noches)|a\s+diario|diariamente|every\s+(day|morning|evening|night)|daily|each\s+(day|morning))\b"#, in: sentence) {
                    let words = match.groups[0].lowercased()
                    var h = hour
                    if !foundTime {
                        if words.contains("tarde") || words.contains("evening") { h = 18 }
                        else if words.contains("noche") || words.contains("night") { h = 21 }
                        else if words.contains("mañana") || words.contains("morning") { h = 8 }
                    }
                    cadence = .daily(hour: h, minute: minute)
                    sentence = sentence.replacingCharacters(in: match.range, with: " ")
                } else if foundTime {
                    cadence = .daily(hour: hour, minute: minute)
                }
            }
        }

        let task = tidy(sentence)
        return Reading(cadence: cadence, task: task, name: name(for: task))
    }

    /// A short name from the task: "dime el tiempo en Blanes" → "Tiempo en Blanes".
    static func name(for task: String) -> String {
        guard let title = ConversationTitle.from(task) else { return "" }
        let cut = title.hasSuffix("…") ? String(title.dropLast()) : title
        return String(cut.prefix(32)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Templates

    /// Routines people actually set up, ready to adapt. The prompt is
    /// written for a model with tools: what to look up, what to leave out,
    /// how long the answer should be — so the result is useful and cheap.
    struct Template: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let name: String
        let prompt: String
        let cadence: Cadence
    }

    static let templates: [Template] = [
        Template(
            id: "morning", title: "Morning briefing", symbol: "sun.horizon",
            name: "Morning briefing",
            prompt: "Give me a morning briefing in under 120 words: today's weather where I live, the two or three news items that matter most to me, and anything on my plate today. Skip anything you are not sure about instead of guessing.",
            cadence: .daily(hour: 8, minute: 0)
        ),
        Template(
            id: "watch", title: "Watch for changes", symbol: "eye",
            name: "Watch for changes",
            prompt: "Check [what to watch — a page, a price, a topic] and tell me only if something changed since last time. If nothing changed, reply with one line saying so.",
            cadence: .daily(hour: 9, minute: 0)
        ),
        Template(
            id: "weekly", title: "Weekly summary", symbol: "calendar",
            name: "Weekly summary",
            prompt: "Summarize the week in [topic] in five bullet points, newest first, with a source for each. End with one thing worth doing next week.",
            cadence: .weekly(days: [1], hour: 9, minute: 0)
        ),
        Template(
            id: "deals", title: "Deals and prices", symbol: "tag",
            name: "Deals",
            prompt: "Look for offers on [product or category] under [budget]. List at most five, best value first, each with price, shop and link. Leave out anything without a clear price.",
            cadence: .daily(hour: 10, minute: 0)
        ),
        Template(
            id: "reminder", title: "Reminder", symbol: "bell",
            name: "Reminder",
            prompt: "Remind me to [what], in one friendly line. No preamble.",
            cadence: .weekly(days: [1, 2, 3, 4, 5], hour: 9, minute: 0)
        ),
        Template(
            id: "learn", title: "Learn something", symbol: "book",
            name: "Daily lesson",
            prompt: "Teach me one thing about [topic] in under 100 words, with one example. Do not repeat a previous lesson; keep a list of what you have covered in your notes.",
            cadence: .daily(hour: 19, minute: 0)
        ),
    ]

    // MARK: Pieces

    private static let dayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let dayLongNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private static func dayNumber(_ word: String) -> Int? {
        let w = word.lowercased()
            .replacingOccurrences(of: "é", with: "e").replacingOccurrences(of: "á", with: "a")
        if w.hasPrefix("lun") || w.hasPrefix("mon") { return 1 }
        if w.hasPrefix("mar") || w.hasPrefix("tue") { return 2 }
        if w.hasPrefix("mie") || w.hasPrefix("wed") { return 3 }
        if w.hasPrefix("jue") || w.hasPrefix("thu") { return 4 }
        if w.hasPrefix("vie") || w.hasPrefix("fri") { return 5 }
        if w.hasPrefix("sab") || w.hasPrefix("sat") { return 6 }
        if w.hasPrefix("dom") || w.hasPrefix("sun") { return 7 }
        return nil
    }

    static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private struct Match {
        let range: Range<String.Index>
        let groups: [String]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(result.range, in: text)
        else { return nil }
        let groups = (0..<result.numberOfRanges).map { index -> String in
            guard let range = Range(result.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
        return Match(range: whole, groups: groups)
    }

    private static func tidy(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: #"^(y|and|,|;|:)\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+(y|and|,|;|:)$"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        guard let first = out.first else { return out }
        return String(first).uppercased() + out.dropFirst()
    }
}
