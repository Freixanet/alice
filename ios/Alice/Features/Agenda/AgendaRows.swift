import SwiftUI

/// One reminder, event or promise from Alice, as Reminders and Calendar draw
/// theirs: a circle in the list's colour to tick (or the calendar's dot), the
/// title with its priority marks, the notes under it, and a line saying when
/// — red once it is late — with the repeat and place symbols after it.
struct AgendaItemRow: View {
    let item: AgendaItem
    let now: Date
    /// A column of times on the left, for a day's list.
    var showsTime = true
    /// "Tomorrow, 18:00" under the title, for lists that are not by day.
    var showsDate = false
    var ticked = false
    var onTick: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    private var tint: Color { AgendaStyle.color(item, fallback: store.accent.primary(scheme)) }
    private var done: Bool { ticked || item.completed }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showsTime {
                time.frame(width: 50, alignment: .leading)
            }
            marker
            VStack(alignment: .leading, spacing: 3) {
                title
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let line = detailLine {
                    line
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    // MARK: Parts

    private var title: some View {
        let marks = ReminderPriority(rawValue: item.priority)?.marks ?? ""
        let prefix = Text(marks.isEmpty ? "" : marks + " ").foregroundStyle(tint).bold()
        let name = Text(item.title).foregroundStyle(done || item.isPast(now) ? .secondary : .primary)
        return Text("\(prefix)\(name)")
            .font(.body)
            .lineLimit(3)
    }

    @ViewBuilder
    private var marker: some View {
        switch item.kind {
        case .event:
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
        case .reminder:
            Button(action: onTick) {
                ZStack {
                    Circle()
                        .strokeBorder(done ? tint : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if done {
                        Circle().fill(tint).padding(4)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityLabel(done ? "Completed" : "Complete")
            .sensoryFeedback(.success, trigger: done) { _, isDone in isDone }
        case .alice:
            Image(systemName: "bell")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var time: some View {
        if item.start == nil {
            Text(" ")
        } else if item.allDay {
            Text("All day")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let start = item.start {
            VStack(alignment: .leading, spacing: 1) {
                Text(start.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(item.isPast(now) ? .secondary : .primary)
                if let end = item.end, end > start {
                    Text(end.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Tomorrow, 18:00 ⟳ 📍Casa" — Reminders' own line under a title.
    private var detailLine: Text? {
        var parts: [Text] = []
        if item.isAlice {
            parts.append(Text("Alice will write to you").foregroundStyle(.secondary))
        } else if let start = item.start {
            // With a time column the time is already said; the date is said
            // when the list is not by day, or when a reminder is late.
            let late = item.isReminder && !done && AgendaStyle.isLate(item, now: now)
            if showsDate || late {
                parts.append(Text(AgendaStyle.when(start, allDay: item.allDay, now: now))
                    .foregroundStyle(late ? Color.red : .secondary))
            }
        }
        if item.recurring {
            parts.append(Text(Image(systemName: "repeat")).foregroundStyle(.secondary))
        }
        if let location = item.location {
            let symbol = Image(systemName: item.isReminder ? "location.fill" : "mappin")
            parts.append(Text("\(symbol) \(location)").foregroundStyle(.secondary))
        }
        guard !parts.isEmpty else { return nil }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0)  \($1)") }
    }

    @ViewBuilder
    private var trailing: some View {
        if item.isNow(now) {
            Text("Now")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.red)
        }
    }
}

enum AgendaStyle {
    static func color(_ item: AgendaItem, fallback: Color) -> Color {
        switch item.kind {
        case let .event(_, color), let .reminder(_, color):
            color.map(Self.color) ?? fallback
        case .alice:
            fallback
        }
    }

    static func color(_ color: AgendaColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }

    /// Past its day, or past its time when it has one.
    static func isLate(_ item: AgendaItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = item.start else { return false }
        return item.allDay ? calendar.startOfDay(for: due) < calendar.startOfDay(for: now) : due < now
    }

    /// "Today", "Tomorrow, 18:00", "Fri 25 Sep, 9:00" — as Reminders says it.
    static func when(_ date: Date, allDay: Bool, now: Date, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = String(localized: "Today")
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            day = String(localized: "Tomorrow")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = String(localized: "Yesterday")
        } else {
            day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return allDay ? day : "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }
}
