import SwiftUI

/// Moving or cancelling an event he already has, as an agent proposed it.
///
/// The card finds the real event in the phone's calendar first — by day,
/// title and time — and shows that, not the agent's words: nothing is moved
/// or removed on a guess. The change happens on his tap, and cancelling asks
/// once more. «No, gracias» closes it, as the other calendar cards do.
struct ChangeEventCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.replySuperseded) private var superseded
    let change: RichCalendarChange
    var language: ChatLanguage = .english

    @State private var found: CalendarSync.Found?
    @State private var looked = false
    @State private var target = Date()
    @State private var working = false
    @State private var confirmingCancel = false
    @State private var problem: String?
    @State private var done: Outcome?
    @State private var dismissed = false

    enum Outcome: Equatable { case moved(Date), cancelled }

    var body: some View {
        Group {
            if dismissed || (superseded && done == nil) {
                EmptyView()
            } else {
                card
            }
        }
        .animation(.snappy(duration: 0.25), value: dismissed)
        .animation(.snappy(duration: 0.25), value: done)
        .task { await locate() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                tile
                VStack(alignment: .leading, spacing: 4) {
                    Text(found?.title ?? change.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .strikethrough(done == .cancelled)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if let done {
                Label(
                    done == .cancelled
                        ? language.pick("Cancelled", "Cancelada")
                        : language.pick("Moved", "Movida"),
                    systemImage: done == .cancelled ? "calendar.badge.minus" : "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(done == .cancelled ? Palette.danger(scheme) : Palette.success(scheme))
            } else if !CalendarSync.hasAccess {
                Text(language.pick("Connect your calendar to change it from here.", "Conecta tu calendario para cambiarla desde aquí."))
                    .font(.footnote).foregroundStyle(.secondary)
                Button(language.pick("Connect", "Conectar")) {
                    Task {
                        if let refused = await store.connectCalendar() { problem = refused } else { await locate(force: true) }
                    }
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(accent)
            } else if looked, found == nil {
                Text(language.pick("I can't find it in your calendar that day.", "No la encuentro en tu calendario ese día."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let found, !found.editable {
                Text(language.pick("That calendar can't be changed from here.", "Ese calendario no se puede cambiar desde aquí."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if found != nil {
                actions
            }

            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5) }
        .confirmationDialog(
            language.pick("Cancel this event?", "¿Cancelar esta cita?"),
            isPresented: $confirmingCancel, titleVisibility: .visible
        ) {
            Button(language.pick("Cancel event", "Cancelar cita"), role: .destructive) { Task { await apply() } }
        } message: {
            Text(language.pick("It is removed from your calendar.", "Se quita de tu calendario."))
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            if change.kind == .move {
                DatePicker(language.pick("New time", "Nueva hora"), selection: $target,
                           displayedComponents: (found?.allDay ?? false) ? [.date] : [.date, .hourAndMinute])
                    .font(.subheadline)
                    .environment(\.locale, language.locale)
            }
            Button {
                if change.kind == .cancel { confirmingCancel = true } else { Task { await apply() } }
            } label: {
                Group {
                    if working {
                        ProgressView()
                    } else {
                        Label(
                            change.kind == .cancel ? language.pick("Cancel event", "Cancelar cita") : language.pick("Move", "Mover"),
                            systemImage: change.kind == .cancel ? "calendar.badge.minus" : "arrow.right.circle"
                        )
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(change.kind == .cancel ? Palette.danger(scheme) : accent)
            .disabled(working)

            Button(language.pick("No, thanks", "No, gracias")) {
                withAnimation(.snappy(duration: 0.25)) { dismissed = true }
                if !superseded { store.sendQuickReply(language.pick("No, leave it.", "No, déjala como está.")) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .disabled(working)
        }
    }

    private var accent: Color { store.accent.primary(scheme) }

    private var shown: Date {
        if case let .moved(date) = done { return date }
        return found?.start ?? change.at ?? change.day ?? Date()
    }

    private var tile: some View {
        VStack(spacing: 1) {
            Text(shown.formatted(.dateTime.weekday(.abbreviated).locale(language.locale)).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(change.kind == .cancel ? Palette.danger(scheme) : accent)
            Text(shown.formatted(.dateTime.day().locale(language.locale)))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 56, height: 58)
        .background(Palette.background(scheme), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Palette.border(scheme), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    /// "17:00 → jue 18:00 · Gràcia", or "17:00 · Gràcia" for a cancellation.
    private var detail: String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale)
        let original = found.map { $0.allDay ? language.pick("All day", "Todo el día") : $0.start.formatted(time) }
            ?? change.time ?? ""
        var parts: [String] = []
        if change.kind == .move, done == nil, let to = change.target {
            let sameDay = Calendar.current.isDate(to, inSameDayAs: found?.start ?? change.day ?? to)
            let label = sameDay ? to.formatted(time)
                : to.formatted(.dateTime.weekday(.abbreviated).day().hour().minute().locale(language.locale))
            parts.append(original.isEmpty ? "→ \(label)" : "\(original) → \(label)")
        } else if !original.isEmpty {
            parts.append(original)
        }
        if let location = found?.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    private func locate(force: Bool = false) async {
        guard force || !looked, let day = change.day else { return }
        found = CalendarSync.find(title: change.title, day: day, time: change.at)
        looked = true
        if let to = change.target { target = to }
    }

    private func apply() async {
        guard let found else { return }
        working = true
        defer { working = false }
        problem = nil
        do {
            switch change.kind {
            case .move:
                try CalendarSync.move(found.identifier, to: target)
                done = .moved(target)
                store.sendQuickReply(language.pick("Done, moved.", "Hecho, movida."))
            case .cancel:
                try CalendarSync.cancel(found.identifier)
                done = .cancelled
                store.sendQuickReply(language.pick("Done, cancelled.", "Hecho, cancelada."))
            }
            await store.syncCalendarNow()
        } catch {
            problem = error.localizedDescription
        }
    }
}
