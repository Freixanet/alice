import SwiftUI

/// A few appointments, one to a row: what, which day, and the time in a
/// pill. A tap opens the day in Calendar.
struct EventsCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let events: [UIComponent.Event]
    var language: ChatLanguage = .english

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().padding(.leading, 58) }
                Button {
                    if let start = event.start, let url = URL(string: "calshow:\(start.timeIntervalSinceReferenceDate)") {
                        openURL(url)
                    }
                } label: {
                    row(event)
                }
                .buttonStyle(.pressable)
                .disabled(event.start == nil)
            }
        }
        .padding(.vertical, 4)
        .componentCard(scheme, padding: 0)
    }

    private func row(_ event: UIComponent.Event) -> some View {
        HStack(spacing: 12) {
            Image(systemName: event.symbol.flatMap { UIImage(systemName: $0) == nil ? nil : $0 } ?? "calendar")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.13), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let start = event.start {
                    Text(start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(language.locale)).capitalizedFirst)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let time = timeText(event) {
                ComponentPill(text: time)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    private var accent: Color { store.accent.primary(scheme) }

    private func timeText(_ event: UIComponent.Event) -> String? {
        guard let start = event.start else { return nil }
        let style = Date.FormatStyle.dateTime.hour().minute().locale(language.locale)
        // A date with no time of day is an all-day event.
        let parts = Calendar.current.dateComponents([.hour, .minute], from: start)
        if parts.hour == 0, parts.minute == 0, event.end == nil { return nil }
        guard let end = event.end, end > start else { return start.formatted(style) }
        return "\(start.formatted(style))–\(end.formatted(style))"
    }
}

/// Steps along a line — flights, a route, a day's plan: the time on the
/// left, a dot on the line, and what happens with an optional tag.
struct TimelineCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let steps: [UIComponent.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text(step.time ?? "")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 50, alignment: .trailing)
                        .padding(.top, 1)
                    rail(first: index == 0, last: index == steps.count - 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                        if let subtitle = step.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let tag = step.tag {
                            ComponentPill(text: tag, tint: accent)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.bottom, index == steps.count - 1 ? 0 : 18)
                    Spacer(minLength: 0)
                    if let url = step.url {
                        Button { openURL(url) } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Palette.muted(scheme), in: .circle)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
        .componentCard(scheme)
    }

    private var accent: Color { store.accent.primary(scheme) }

    /// The dot and the line through it, joined row to row.
    private func rail(first: Bool, last: Bool) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? .clear : Palette.border(scheme)).frame(width: 1.5, height: 8)
                Rectangle().fill(last ? .clear : Palette.border(scheme)).frame(width: 1.5)
            }
            Circle()
                .fill(accent)
                .frame(width: 9, height: 9)
                .overlay { Circle().stroke(Palette.card(scheme), lineWidth: 2.5) }
                .padding(.top, 4)
        }
        .frame(width: 12)
    }
}

/// A month from the person's own calendar: days with something on carry a
/// dot, and tapping one lists what is on it. Read on the phone, never sent
/// by the agent — the agent only says which month.
struct MonthCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(AppStore.self) private var store
    let month: String?
    var language: ChatLanguage = .english

    @State private var shown: Date
    @State private var events: [CalendarSync.Event] = []
    @State private var selected: Date?
    @State private var hasAccess = CalendarSync.hasAccess

    init(month: String?, language: ChatLanguage = .english) {
        self.month = month
        self.language = language
        _shown = State(initialValue: Self.parse(month) ?? .now)
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = language.locale
        return calendar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(shown.formatted(.dateTime.month(.wide).year().locale(language.locale)).capitalizedFirst)
                    .font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    step(-1, symbol: "chevron.left")
                    step(1, symbol: "chevron.right")
                }
            }

            grid

            if !hasAccess {
                Button {
                    Task {
                        if await store.connectCalendar() == nil { hasAccess = CalendarSync.hasAccess }
                        await load()
                    }
                } label: {
                    Label(language.pick("Connect your calendar to see your events", "Conecta tu calendario para ver tus eventos"), systemImage: "calendar.badge.plus")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.pressable)
                .foregroundStyle(accent)
            } else if let selected {
                dayList(selected)
            }
        }
        .componentCard(scheme)
        .task(id: shown) { await load() }
        .animation(.snappy(duration: 0.25), value: selected)
    }

    private var accent: Color { store.accent.primary(scheme) }

    private func step(_ months: Int, symbol: String) -> some View {
        Button {
            shown = calendar.date(byAdding: .month, value: months, to: shown) ?? shown
            selected = nil
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(Palette.muted(scheme), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .foregroundStyle(.secondary)
    }

    private var grid: some View {
        let days = monthDays()
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let busy = !eventsOn(day).isEmpty
        return Button {
            selected = isSelected ? nil : day
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday || isSelected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Palette.card(scheme) : isToday ? accent : .primary)
                    .frame(width: 30, height: 30)
                    .background {
                        if isSelected { Circle().fill(accent) }
                    }
                Circle()
                    .fill(busy ? accent.opacity(0.8) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(language.locale)))
        .accessibilityValue(busy ? language.pick("Has events", "Con eventos") : "")
    }

    @ViewBuilder
    private func dayList(_ day: Date) -> some View {
        let list = eventsOn(day)
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 6)
            if list.isEmpty {
                Text(language.pick("Nothing that day", "Nada ese día"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, event in
                Button {
                    if let url = URL(string: "calshow:\(event.start.timeIntervalSinceReferenceDate)") { openURL(url) }
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(event.allDay
                                 ? language.pick("All day", "Todo el día")
                                 : event.start.formatted(.dateTime.hour().minute().locale(language.locale)) + (event.location.map { " · \($0)" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable)
            }
        }
        .transition(.opacity)
    }

    private func eventsOn(_ day: Date) -> [CalendarSync.Event] {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return [] }
        let start = calendar.startOfDay(for: day)
        return events.filter { $0.start < next && $0.end > start }
    }

    /// The month's days, with blanks before the first so it falls on its weekday.
    private func monthDays() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: shown),
              let count = calendar.range(of: .day, in: .month, for: shown)?.count
        else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        return Array(repeating: nil, count: leading) + days.map(Optional.some)
    }

    private func load() async {
        hasAccess = CalendarSync.hasAccess
        guard hasAccess, let interval = calendar.dateInterval(of: .month, for: shown) else {
            events = []
            return
        }
        events = await CalendarSync.events(from: interval.start, to: interval.end)
    }

    /// `2026-09`, or a full date within the month.
    nonisolated static func parse(_ month: String?) -> Date? {
        guard let month else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM", "yyyy-MM-dd"] {
            format.dateFormat = pattern
            if let date = format.date(from: String(month.prefix(pattern.count))) { return date }
        }
        return nil
    }
}

extension String {
    /// "septiembre de 2026" → "Septiembre de 2026": Spanish writes months in
    /// lower case, but a heading starts with a capital.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
