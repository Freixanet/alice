import Foundation

/// A piece of interface an agent puts in its reply, so the answer is something
/// to act on rather than a paragraph to read: places to pick from, a map, an
/// agenda, flights on a line, products, phrases to hear, a draft to send, a
/// month, an article.
///
/// Written by the agent as a fenced block — ```alice-ui followed by one JSON
/// object with a `type` — and drawn natively by the app. Anything it cannot
/// read is shown as the code it is, so nothing an agent wrote is lost; a
/// field that is missing is left out, never filled in.
enum UIComponent: Equatable, Sendable {
    case places([Place])
    case map(title: String?, places: [Place])
    case events([Event])
    case timeline([Step])
    case products([Product])
    case phrases(language: String?, items: [Phrase])
    case email(Email)
    /// A month drawn from the person's own calendar on this phone.
    case calendar(month: String?)
    case article(Article)

    struct Place: Equatable, Sendable, Identifiable {
        var id: String { title + (query ?? "") }
        let title: String
        let subtitle: String?
        let image: URL?
        let url: URL?
        /// What to look it up by in Maps when no coordinates are given.
        let query: String?
        let latitude: Double?
        let longitude: Double?
    }

    struct Event: Equatable, Sendable, Identifiable {
        var id: String { title + (start?.description ?? "") }
        let title: String
        let start: Date?
        let end: Date?
        let symbol: String?
    }

    struct Step: Equatable, Sendable, Identifiable {
        var id: String { (time ?? "") + title }
        let time: String?
        let title: String
        let subtitle: String?
        let tag: String?
        let url: URL?
    }

    struct Product: Equatable, Sendable, Identifiable {
        var id: String { title + (url?.absoluteString ?? "") }
        let brand: String?
        let title: String
        let price: String?
        let image: URL?
        let url: URL?
    }

    struct Phrase: Equatable, Sendable, Identifiable {
        var id: String { text }
        let text: String
        let translation: String?
        let note: String?
    }

    struct Email: Equatable, Sendable {
        let to: String?
        let subject: String?
        let body: String
    }

    struct Article: Equatable, Sendable {
        struct Section: Equatable, Sendable, Identifiable {
            var id: String { heading ?? text }
            let heading: String?
            let text: String
        }

        let title: String
        let image: URL?
        let sections: [Section]
    }

    /// The fence languages an agent may use.
    static func accepts(_ language: String?) -> Bool {
        guard let language = language?.lowercased() else { return false }
        return language == "alice-ui" || language == "alice"
    }

    init?(json text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (object["type"] as? String)?.lowercased()
        else { return nil }
        let items = (object["items"] as? [[String: Any]]) ?? []
        switch type {
        case "places":
            let places = items.compactMap(Self.place)
            guard !places.isEmpty else { return nil }
            self = .places(places)
        case "map":
            let places = ((object["places"] as? [[String: Any]]) ?? items).compactMap(Self.place)
            guard !places.isEmpty else { return nil }
            self = .map(title: Self.string(object["title"]), places: places)
        case "events", "agenda":
            let events = items.compactMap { row -> Event? in
                guard let title = Self.string(row["title"]) else { return nil }
                return Event(title: title, start: Self.date(row["start"]), end: Self.date(row["end"]),
                             symbol: Self.string(row["symbol"]))
            }
            guard !events.isEmpty else { return nil }
            self = .events(events)
        case "timeline":
            let steps = items.compactMap { row -> Step? in
                guard let title = Self.string(row["title"]) else { return nil }
                return Step(time: Self.string(row["time"]), title: title, subtitle: Self.string(row["subtitle"]),
                            tag: Self.string(row["tag"]), url: Self.url(row["url"]))
            }
            guard !steps.isEmpty else { return nil }
            self = .timeline(steps)
        case "products":
            let products = items.compactMap { row -> Product? in
                guard let title = Self.string(row["title"]) else { return nil }
                return Product(brand: Self.string(row["brand"]), title: title, price: Self.string(row["price"]),
                               image: Self.url(row["image"]), url: Self.url(row["url"]))
            }
            guard !products.isEmpty else { return nil }
            self = .products(products)
        case "phrases":
            let phrases = items.compactMap { row -> Phrase? in
                guard let text = Self.string(row["text"]) else { return nil }
                return Phrase(text: text, translation: Self.string(row["translation"]), note: Self.string(row["note"]))
            }
            guard !phrases.isEmpty else { return nil }
            self = .phrases(language: Self.string(object["language"]), items: phrases)
        case "email":
            guard let body = Self.string(object["body"]) else { return nil }
            self = .email(Email(to: Self.string(object["to"]), subject: Self.string(object["subject"]), body: body))
        case "calendar":
            self = .calendar(month: Self.string(object["month"]))
        case "article":
            guard let title = Self.string(object["title"]) else { return nil }
            let sections = ((object["sections"] as? [[String: Any]]) ?? []).compactMap { row -> Article.Section? in
                guard let text = Self.string(row["text"]) else { return nil }
                return Article.Section(heading: Self.string(row["heading"]), text: text)
            }
            self = .article(Article(title: title, image: Self.url(object["image"]), sections: sections))
        default:
            return nil
        }
    }

    private static func place(_ row: [String: Any]) -> Place? {
        guard let title = string(row["title"]) ?? string(row["name"]) else { return nil }
        return Place(
            title: title, subtitle: string(row["subtitle"]), image: url(row["image"]), url: url(row["url"]),
            query: string(row["query"]) ?? string(row["address"]),
            latitude: number(row["lat"]) ?? number(row["latitude"]),
            longitude: number(row["lon"]) ?? number(row["longitude"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }

    /// Only web addresses: an image or link an agent names must be one it found.
    private static func url(_ value: Any?) -> URL? {
        guard let text = string(value), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}
