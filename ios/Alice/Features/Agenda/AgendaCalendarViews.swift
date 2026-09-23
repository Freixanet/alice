import SwiftUI

/// Calendar's week strip: the days of one week with their initials, today's
/// number in red, the chosen day in a filled circle, a dot under days with
/// something on them. Swiping moves a week, keeping the weekday.
struct AgendaWeekStrip: View {
    @Binding var selected: Date
    let hasItems: (Date) -> Bool
    var now = Date()

    @State private var week = 0
    private let calendar = Calendar.current
    private static let span = 260

    var body: some View {
        TabView(selection: $week) {
            ForEach(-Self.span...Self.span, id: \.self) { offset in
                HStack(spacing: 0) {
                    ForEach(days(of: offset), id: \.self) { day in
                        AgendaDayCell(day: day, selected: calendar.isDate(day, inSameDayAs: selected),
                                      now: now, dot: hasItems(day), compact: false) {
                            select(day)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 8)
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 66)
        .onAppear { week = offset(of: selected) }
        .onChange(of: selected) { _, day in
            let target = offset(of: day)
            if target != week { withAnimation(.snappy) { week = target } }
        }
        .onChange(of: week) { _, offset in
            // Swiped: the same weekday in the new week.
            let current = self.offset(of: selected)
            guard offset != current,
                  let moved = calendar.date(byAdding: .weekOfYear, value: offset - current, to: selected) else { return }
            selected = moved
        }
    }

    private func select(_ day: Date) {
        withAnimation(.snappy(duration: 0.2)) { selected = day }
    }

    private func startOfWeek(_ date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private func offset(of day: Date) -> Int {
        let weeks = calendar.dateComponents([.weekOfYear], from: startOfWeek(now), to: startOfWeek(day)).weekOfYear ?? 0
        return max(-Self.span, min(Self.span, weeks))
    }

    private func days(of offset: Int) -> [Date] {
        guard let start = calendar.date(byAdding: .weekOfYear, value: offset, to: startOfWeek(now)) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

/// One day in the strip or the month grid.
struct AgendaDayCell: View {
    let day: Date
    let selected: Bool
    let now: Date
    let dot: Bool
    /// The month grid: no weekday initial above the number.
    let compact: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme
    private let calendar = Calendar.current

    private var isToday: Bool { calendar.isDate(day, inSameDayAs: now) }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                if !compact {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(day.formatted(.dateTime.day()))
                    .font(.system(.body, design: .default).weight(selected || isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                    .frame(width: 34, height: 34)
                    .background {
                        if selected {
                            Circle().fill(isToday ? Color.red : Color.primary)
                        }
                    }
                Circle()
                    .fill(dot ? Color.secondary.opacity(0.7) : .clear)
                    .frame(width: 5, height: 5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(day.formatted(date: .complete, time: .omitted)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var numberColor: Color {
        if selected { return scheme == .dark && !isToday ? .black : .white }
        return isToday ? .red : .primary
    }
}

/// Calendar's month: the weekday initials, the weeks of the month, today in
/// red and the chosen day circled. Swiping or the arrows move a month.
struct AgendaMonthGrid: View {
    @Binding var selected: Date
    let hasItems: (Date) -> Bool
    var now = Date()

    @State private var month = Date()
    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()).capitalized)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.numericText())
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous Month")
                    .padding(.trailing, 18)
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next Month")
            }
            .padding(.horizontal, 20)
            .font(.body.weight(.semibold))

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)

            let days = grid(for: month)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        AgendaDayCell(day: day, selected: calendar.isDate(day, inSameDayAs: selected),
                                      now: now, dot: hasItems(day), compact: true) {
                            withAnimation(.snappy(duration: 0.2)) { selected = day }
                        }
                    } else {
                        Color.clear.frame(height: 42)
                    }
                }
            }
            .padding(.horizontal, 8)
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 50 else { return }
                move(value.translation.width < 0 ? 1 : -1)
            })
        }
        .onAppear { month = startOfMonth(selected) }
        .onChange(of: selected) { _, day in
            let start = startOfMonth(day)
            if start != month { withAnimation(.snappy) { month = start } }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    private func move(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(.snappy) {
            month = next
            // Today when the month has it; otherwise its first day.
            selected = calendar.isDate(now, equalTo: next, toGranularity: .month) ? now : next
        }
    }

    /// The month's days in weeks, blanks before the first.
    private func grid(for month: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: lead) + days.map { Optional($0) }
    }
}
