import Foundation
import NaturalLanguage

/// The language a conversation is in, for what the app draws inside it.
///
/// The app's own screens follow the phone, but a card in a chat — adding an
/// event, connecting the calendar — is part of what Alice said, and a Spanish
/// reply with "WED · When · Connect & Add" under it read as two voices. It
/// follows the message it sits in.
enum ChatLanguage: String, Sendable {
    case english = "en"
    case spanish = "es"

    /// The message's own language, when it is one the cards speak; English otherwise.
    static func of(_ text: String) -> ChatLanguage {
        if let cached = cache[text] { return cached }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english, .catalan, .french, .italian, .portuguese]
        recognizer.processString(text)
        let found: ChatLanguage = recognizer.dominantLanguage == .spanish ? .spanish : .english
        if cache.count > 200 { cache.removeAll() }
        cache[text] = found
        return found
    }

    nonisolated(unsafe) private static var cache: [String: ChatLanguage] = [:]

    var locale: Locale { Locale(identifier: self == .spanish ? "es_ES" : "en_US") }

    func pick(_ english: String, _ spanish: String) -> String {
        self == .spanish ? spanish : english
    }
}
