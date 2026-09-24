import Foundation

/// A date said in words inside a reminder's title — "mañana a las 18:00",
/// "el viernes", "tomorrow at 6 PM" — found on the phone by the same
/// detector Apple's apps use, and offered to the person as a suggestion,
/// as Reminders does, rather than applied behind their back.
struct ReminderDateSuggestion: Equatable, Sendable {
    /// The words that said it, as typed.
    let phrase: String
    let date: Date
    /// Whether a time was said, or only a day.
    let hasTime: Bool
    /// The title with those words taken out.
    let remainingTitle: String
}

enum ReminderParsing {
    /// The last date said in `text`, if any. A lone number is not a date.
    static func suggestion(in text: String, now: Date = Date(), calendar: Calendar = .current) -> ReminderDateSuggestion? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = text as NSString
        guard let match = detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let date = match.date else { return nil }
        let phrase = ns.substring(with: match.range)
        guard phrase.contains(where: \.isLetter) else { return nil }
        let hasTime = saysTime(phrase)
        let day = hasTime ? date : calendar.startOfDay(for: date)
        var remaining = ns.replacingCharacters(in: match.range, with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
        // "Llamar a mamá el viernes" → "Llamar a mamá", not "Llamar a mamá el".
        for tail in [" para el", " a las", " para", " el", " la", " on", " at", " by"]
        where remaining.lowercased().hasSuffix(tail) {
            remaining = String(remaining.dropLast(tail.count))
            break
        }
        return ReminderDateSuggestion(phrase: phrase, date: day, hasTime: hasTime, remainingTitle: remaining)
    }

    /// "a las 10", "18:00", "6 PM", "5 de la tarde", "at noon" say a time;
    /// "mañana", "el viernes", "1 de octubre" do not.
    static func saysTime(_ phrase: String) -> Bool {
        let lower = phrase.lowercased()
        if lower.range(of: #"\d{1,2}[:.h]\d{2}"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\d\s*(am|pm|a\.m\.|p\.m\.|h\b)"#, options: .regularExpression) != nil { return true }
        let words = ["a las", "a la ", "at ", "de la tarde", "de la mañana", "de la noche", "mediodía",
                     "medianoche", "noon", "midnight", "tonight", "esta noche", "esta tarde", "this evening"]
        return words.contains { lower.contains($0) }
    }
}
