import Foundation

/// When a message was sent, said the way a messaging app says it.
///
/// Two lengths: over a reply there is room for the day and the time; at the
/// end of a row in the bots list there is room for one of them.
enum MessageTime {

    /// Hermes sends a timestamp with each persisted turn, and a turn that came
    /// without one is stored at the epoch. That means "unknown", not 1970.
    static func isKnown(_ date: Date) -> Bool {
        date.timeIntervalSince1970 > 86_400
    }

    /// Over a reply: "10:32", "Yesterday 10:32", "Mon 10:32", "8 Sep, 10:32".
    static func caption(
        _ date: Date, now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard isKnown(date) else { return nil }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        switch age(of: date, now: now, calendar: calendar) {
        case .today: return time
        case .yesterday: return "Yesterday \(time)"
        case .thisWeek: return "\(date.formatted(style.weekday(.abbreviated))) \(time)"
        case .thisYear: return "\(date.formatted(style.day().month(.abbreviated))), \(time)"
        case .older: return "\(date.formatted(style.day().month(.abbreviated).year())), \(time)"
        }
    }

    /// At the end of a row: "10:32", "Yesterday", "Mon", "8 Sep".
    static func short(
        _ date: Date, now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard isKnown(date) else { return nil }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch age(of: date, now: now, calendar: calendar) {
        case .today: return date.formatted(style.hour().minute())
        case .yesterday: return "Yesterday"
        case .thisWeek: return date.formatted(style.weekday(.abbreviated))
        case .thisYear: return date.formatted(style.day().month(.abbreviated))
        case .older: return date.formatted(style.day().month(.abbreviated).year())
        }
    }

    enum Age: Equatable { case today, yesterday, thisWeek, thisYear, older }

    static func age(of date: Date, now: Date, calendar: Calendar) -> Age {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 0 { return .today }
        if days == 1 { return .yesterday }
        if days < 7 { return .thisWeek }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? .thisYear : .older
    }
}
