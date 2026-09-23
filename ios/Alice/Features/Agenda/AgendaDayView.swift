import SwiftUI

/// Calendar's day: an all-day band on top, then the hours, with events as
/// blocks in their calendar's colour, reminders with a time as a line with
/// their circle, and a red line at the current time. Tapping an empty hour
/// starts an event there.
struct AgendaDayView: View {
    let day: Date
    let items: [AgendaItem]
    let now: Date
    var ticking: Set<String> = []
    var jump = 0
    let onOpen: (AgendaItem) -> Void
    let onTick: (AgendaItem) -> Void
    let onNewEvent: (Date) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 54
    private let gutter: CGFloat = 52

    private var dayStart: Date { calendar.startOfDay(for: day) }
    private var isToday: Bool { calendar.isDate(day, inSameDayAs: now) }

    /// All-day events, reminders without a time, and — today — what is late.
    private var allDay: [AgendaItem] {
        items.filter { item in
            if item.isReminder { return item.allDay || (item.start ?? dayStart) < dayStart }
            return item.allDay || (item.start ?? dayStart) < dayStart && !item.isAlice
        }
    }

    private var timedEvents: [AgendaItem] {
        items.filter { !$0.isReminder && !$0.allDay && ($0.start ?? dayStart) >= dayStart }
    }

    private var timedReminders: [AgendaItem] {
        items.filter { $0.isReminder && !$0.allDay && ($0.start ?? dayStart) >= dayStart }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 6)
            if !allDay.isEmpty {
                allDayBand
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geometry in
                        timeline(width: geometry.size.width)
                    }
                    .frame(height: hourHeight * 24 + 16)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: day) { scroll(proxy) }
                .onChange(of: jump) { withAnimation(.snappy) { scroll(proxy) } }
            }
        }
    }

    // MARK: All day

    private var allDayBand: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(allDay.prefix(6)) { item in
                    if item.isReminder {
                        reminderLine(item)
                    } else {
                        eventChip(item, height: 24)
                            .onTapGesture { onOpen(item) }
                    }
                }
                if allDay.count > 6 {
                    Text("\(allDay.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    // MARK: Hours

    private func timeline(width: CGFloat) -> some View {
        let columns = Self.layout(timedEvents, dayStart: dayStart)
        let lane = width - gutter - 8
        return ZStack(alignment: .topLeading) {
            // The grid, which also takes the tap for a new event.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 8) {
                        Text(hourLabel(hour))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: gutter - 8, alignment: .trailing)
                            .offset(y: -7)
                            .opacity(isToday && abs(minutes(now) - hour * 60) < 12 ? 0 : 1)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(height: 0.5)
                    }
                    .frame(height: hourHeight, alignment: .top)
                    .id(hour)
                }
            }
            .padding(.top, 8)
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { point in
                let hour = max(0, min(23, Int((point.y - 8) / hourHeight)))
                if let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) {
                    onNewEvent(start)
                }
            }

            ForEach(timedEvents) { item in
                let slot = columns[item.id] ?? (0, 1)
                let frame = block(for: item)
                eventChip(item, height: frame.height)
                    .frame(width: max(lane / CGFloat(slot.count) - 2, 20), height: frame.height)
                    .offset(x: gutter + lane / CGFloat(slot.count) * CGFloat(slot.column), y: frame.y + 8)
                    .onTapGesture { onOpen(item) }
            }

            ForEach(timedReminders) { item in
                reminderLine(item)
                    .frame(width: lane, alignment: .leading)
                    .offset(x: gutter, y: y(for: item.start ?? dayStart) + 8 - 10)
            }

            if isToday {
                nowLine(width: width)
                    .offset(y: y(for: now) + 8 - 8)
            }
        }
    }

    private func nowLine(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.red, in: .capsule)
                .frame(width: gutter, alignment: .trailing)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1.5)
        }
        .frame(width: width, height: 16)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    private func eventChip(_ item: AgendaItem, height: CGFloat) -> some View {
        let tint = AgendaStyle.color(item, fallback: store.accent.primary(scheme))
        return HStack(alignment: .top, spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(height > 40 ? 2 : 1)
                if height > 40, let start = item.start {
                    Text(item.location ?? start.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(item.isPast(now) ? .secondary : .primary)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(tint.opacity(scheme == .dark ? 0.28 : 0.16), in: .rect(cornerRadius: 5))
        .clipShape(.rect(cornerRadius: 5))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func reminderLine(_ item: AgendaItem) -> some View {
        let tint = AgendaStyle.color(item, fallback: store.accent.primary(scheme))
        let done = ticking.contains(item.id)
        return HStack(spacing: 6) {
            Button { onTick(item) } label: {
                ZStack {
                    Circle().strokeBorder(done ? tint : Color.secondary.opacity(0.6), lineWidth: 1.3)
                    if done { Circle().fill(tint).padding(3) }
                }
                .frame(width: 16, height: 16)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete")
            Text(item.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AgendaStyle.isLate(item, now: now) && !done ? Color.red : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .contentShape(.rect)
        .onTapGesture { onOpen(item) }
    }

    // MARK: Geometry

    private func minutes(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func y(for date: Date) -> CGFloat {
        let fromStart = max(0, min(24 * 60, date.timeIntervalSince(dayStart) / 60))
        return CGFloat(fromStart) / 60 * hourHeight
    }

    private func block(for item: AgendaItem) -> (y: CGFloat, height: CGFloat) {
        let start = item.start ?? dayStart
        let end = min(item.end ?? start.addingTimeInterval(3600), dayStart.addingTimeInterval(86_400))
        let top = y(for: start)
        return (top, max(y(for: end) - top - 1, 20))
    }

    private func hourLabel(_ hour: Int) -> String {
        guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) else { return "" }
        return date.formatted(.dateTime.hour())
    }

    /// An hour above now, or above the first thing of the day.
    private func scroll(_ proxy: ScrollViewProxy) {
        let first = timedEvents.compactMap(\.start).min().map { minutes($0) / 60 }
        let target = isToday ? minutes(now) / 60 : (first ?? 8)
        proxy.scrollTo(max(0, target - 1), anchor: .top)
    }

    /// Side-by-side columns for events that overlap, as Calendar lays them.
    nonisolated static func layout(_ events: [AgendaItem], dayStart: Date) -> [String: (column: Int, count: Int)] {
        let sorted = events.sorted { ($0.start ?? dayStart, $0.end ?? dayStart) < ($1.start ?? dayStart, $1.end ?? dayStart) }
        var result: [String: (Int, Int)] = [:]
        var cluster: [(id: String, column: Int)] = []
        var columnsEnd: [Date] = []
        var clusterEnd = Date.distantPast

        func close() {
            let count = max(columnsEnd.count, 1)
            for entry in cluster { result[entry.id] = (entry.column, count) }
            cluster = []
            columnsEnd = []
        }

        for event in sorted {
            let start = event.start ?? dayStart
            let end = max(event.end ?? start, start.addingTimeInterval(20 * 60))
            if start >= clusterEnd { close() }
            if let free = columnsEnd.firstIndex(where: { $0 <= start }) {
                columnsEnd[free] = end
                cluster.append((event.id, free))
            } else {
                columnsEnd.append(end)
                cluster.append((event.id, columnsEnd.count - 1))
            }
            clusterEnd = max(clusterEnd, end)
        }
        close()
        return result
    }
}
