import SwiftUI

private struct ReplySupersededKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for a reply the person has written after: its offers are no
    /// longer the question on the table. Set per row by the transcript.
    var replySuperseded: Bool {
        get { self[ReplySupersededKey.self] }
        set { self[ReplySupersededKey.self] = newValue }
    }
}

/// An agent's offer to connect something, in the chat where it helps.
///
/// An agent that needs the person's calendar and does not have it ends its
/// reply with `[Conectar calendario](alice://connect/calendar)` (its
/// instructions say when, and to offer it once). The link becomes this card:
/// what connecting gives, one tap to do it, and one to say not now — which
/// Hermes remembers, so the offer is not made again. Settings › Connections
/// keeps the way back for a change of mind.
struct ConnectOfferCard: View {
    /// What the app knows how to connect.
    nonisolated static let services: Set<String> = ["calendar"]

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.replySuperseded) private var superseded
    let service: String
    var language: ChatLanguage = .english

    @State private var working = false
    @State private var problem: String?

    /// Declined, or passed over by a later message while still unconnected:
    /// the offer closes. Settings › Connections keeps the way back.
    private var closed: Bool {
        switch store.calendarLink {
        case .declined: true
        case .notConnected, .unknown: superseded
        case .connected: false
        }
    }

    var body: some View {
        if !closed {
            offer
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.pick("Connect your calendar", "Conecta tu calendario"))
                        .font(.headline)
                    Text(language.pick("So your agents can plan around your day: what you have, when you are free, what is coming up.", "Para que tus agentes planifiquen contando con tu día: lo que tienes, cuándo estás libre y lo que viene."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch store.calendarLink {
            case .connected:
                Label(language.pick("Connected", "Conectado"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.success(scheme))
            case .declined:
                EmptyView()
            case .notConnected, .unknown:
                HStack(spacing: 10) {
                    Button {
                        Task { await connect() }
                    } label: {
                        Group {
                            if working {
                                ProgressView()
                            } else {
                                Label(language.pick("Connect", "Conectar"), systemImage: "calendar.badge.plus")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(accent)

                    Button(language.pick("Not now", "Ahora no")) {
                        Task { await decline() }
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.primary)
                }
                .disabled(working || store.isSending)
                Label(language.pick("Your events go only to your own Hermes. Alice adds only what you confirm.", "Tus eventos solo van a tu propio Hermes. Alice solo añade lo que tú confirmas."), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .animation(.snappy(duration: 0.25), value: store.calendarLink)
        .task { if store.calendarLink == .unknown { await store.refreshCalendarLink() } }
        .accessibilityElement(children: .contain)
    }

    private var accent: Color { store.accent.primary(scheme) }

    private func connect() async {
        working = true
        defer { working = false }
        problem = nil
        if let problem = await store.connectCalendar() {
            self.problem = problem
        } else {
            // The agent carries on with what it was asked, now with the day in view.
            store.sendQuickReply(language.pick("Done, my calendar is connected.", "Listo, ya he conectado el calendario."))
        }
    }

    private func decline() async {
        await store.declineCalendar()
        store.sendQuickReply(language.pick("Not now.", "Ahora no."))
    }
}

/// Settings › Connections › Calendar: the same connection, whenever the
/// person wants it, whatever they said in a chat before.
struct CalendarConnectionRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var working = false
    @State private var problem: String?
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The icon on the name's baseline, the status one line under it.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "calendar")
                    .foregroundStyle(store.accent.primary(scheme))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar")
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                if working {
                    ProgressView()
                } else if store.calendarLink.isConnected {
                    Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                        .buttonStyle(.borderless)
                } else {
                    Button("Connect") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(store.accent.primary(scheme))
                }
            }
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger(scheme))
            }
        }
        .task { await store.refreshCalendarLink() }
        .confirmationDialog(
            "Disconnect your calendar?", isPresented: $confirmingDisconnect, titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your events are deleted from your Hermes and your agents stop seeing them. Calendar access for Alice stays in iOS Settings until you turn it off there.")
        }
    }

    private var status: String {
        switch store.calendarLink {
        case let .connected(updatedAt):
            guard let updatedAt else { return "Connected" }
            return "Connected · \(updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
        case .declined: return "Declined in a chat"
        case .notConnected: return "Not connected"
        case .unknown: return "Checking…"
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        problem = await store.connectCalendar()
    }

    private func disconnect() async {
        working = true
        defer { working = false }
        problem = await store.disconnectCalendar()
    }
}

/// An event an agent proposes, added to the person's calendar on one tap.
///
/// "Tengo peluquería el miércoles" is best answered by putting it in the
/// calendar, which reminds on its own. The agent fills in what it heard; the
/// person sets the time if it was not said, and nothing is written until
/// they tap Add. Without calendar access, that tap is where it is asked for.
struct AddEventCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.replySuperseded) private var superseded
    let proposed: RichCalendarEvent
    var language: ChatLanguage = .english

    @State private var start = Date()
    @State private var allDay = false
    @State private var prepared = false
    @State private var working = false
    @State private var problem: String?
    @State private var added: Date?
    /// Whether the time on the card is one somebody gave: the agent, from
    /// what was said, or the person, here. Until then it is not shown as
    /// known — a haircut at "10:00" that nobody said was an invention.
    @State private var timeChosen = false
    @State private var initialStart: Date?
    /// «No, gracias» on this card: it closes and stays closed.
    @State private var dismissed = false
    /// Passed over, then asked for again from its one-line form.
    @State private var reopened = false

    var body: some View {
        Group {
            if dismissed, added == nil {
                EmptyView()
            } else if store.calendarLink == .declined, added == nil {
                // He said not now to the calendar: nothing about it, only the
                // reminder Alice would have offered before there was a calendar.
                if !superseded { reminderOffer }
            } else if superseded, added == nil, !reopened {
                // The conversation moved on without using it: the tool closes
                // to one quiet line, still there if he changes his mind.
                collapsed
            } else {
                card
            }
        }
        .animation(.snappy(duration: 0.25), value: dismissed)
        .animation(.snappy(duration: 0.25), value: reopened)
        .onAppear { if AddEventCard.dismissedBefore(key) { dismissed = true } }
    }

    private var collapsed: some View {
        Button {
            reopened = true
        } label: {
            Label(language.pick("Add “\(proposed.title)” to your calendar", "Añadir «\(proposed.title)» al calendario"),
                  systemImage: "calendar.badge.plus")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.pressable)
    }

    private func dismiss() {
        AddEventCard.rememberDismissed(key)
        withAnimation(.snappy(duration: 0.25)) { dismissed = true }
        // Said to the agent too, so the conversation reads as he left it.
        if !superseded { store.sendQuickReply(language.pick("No, thanks.", "No, gracias.")) }
    }

    private var reminderOffer: some View {
        HStack(spacing: 8) {
            ForEach([language.pick("Yes, remind me", "Sí, recuérdamelo"), "No"], id: \.self) { reply in
                Button(reply) { store.sendQuickReply(reply) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.primary)
                    .disabled(store.isSending)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            // A date tile, the way Calendar shows a day, with the event beside
            // it and centred on it: a round icon at the top of a small line of
            // text made the title look like an afterthought.
            HStack(alignment: .center, spacing: 14) {
                dateTile
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposed.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(needsTime ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }

            if let added {
                HStack {
                    Label(language.pick("Added to your calendar", "Añadido a tu calendario"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.success(scheme))
                    Spacer()
                    Button(language.pick("Open", "Abrir")) {
                        if let url = URL(string: "calshow:\(added.timeIntervalSinceReferenceDate)") {
                            openURL(url)
                        }
                    }
                    .font(.subheadline)
                }
            } else {
                VStack(spacing: 8) {
                    DatePicker(
                        language.pick("When", "Cuándo"), selection: $start,
                        displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]
                    )
                    Toggle(language.pick("All day", "Todo el día"), isOn: $allDay)
                }
                .font(.subheadline)
                // The picker's day and time in the conversation's language too.
                .environment(\.locale, language.locale)

                Button {
                    Task { await add() }
                } label: {
                    Group {
                        if working {
                            ProgressView()
                        } else if needsAccess {
                            Label(language.pick("Connect & Add", "Conectar y añadir"), systemImage: "calendar.badge.plus")
                        } else {
                            Label(language.pick("Add to Calendar", "Añadir al calendario"), systemImage: "plus")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(accent)
                .disabled(working)

                Button(language.pick("No, thanks", "No, gracias")) { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
                    .buttonStyle(.pressable)
                    .disabled(working)

                // One line under the buttons: what is added and, the first time,
                // that adding connects the calendar.
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .animation(.snappy(duration: 0.25), value: added)
        .sensoryFeedback(.success, trigger: added) { old, new in old == nil && new != nil }
        .onAppear(perform: prepare)
        .onChange(of: start) { _, value in
            if let initialStart, value != initialStart { timeChosen = true }
        }
        .task { if store.calendarLink == .unknown { await store.refreshCalendarLink() } }
    }

    private var footnote: String {
        let reminder = allDay
            ? language.pick("Reminder that morning.", "Aviso esa mañana.")
            : language.pick("Reminder an hour before.", "Aviso una hora antes.")
        return needsAccess
            ? language.pick("iOS asks once to connect your calendar.", "iOS te pedirá una vez conectar tu calendario.") + " " + reminder
            : reminder
    }

    /// Adding is also connecting when the app has no calendar access yet,
    /// and the card says so rather than leaving iOS's prompt as a surprise.
    private var needsAccess: Bool { !CalendarSync.hasAccess }

    private var accent: Color { store.accent.primary(scheme) }

    private var shown: Date { added ?? start }

    private var dateTile: some View {
        VStack(spacing: 1) {
            Text(shown.formatted(.dateTime.weekday(.abbreviated).locale(language.locale)).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(accent)
            Text(shown.formatted(.dateTime.day().locale(language.locale)))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(width: 56, height: 58)
        .background(Palette.background(scheme), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if added != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.success(scheme))
                    .background(Palette.card(scheme), in: .circle)
                    .offset(x: 6, y: -6)
            }
        }
        .accessibilityHidden(true)
    }

    private var needsTime: Bool { !allDay && !timeChosen && added == nil }

    /// "17:00 · Gràcia" — the day is already on the tile beside it.
    private var detail: String {
        var parts: [String] = []
        if allDay {
            parts.append(language.pick("All day", "Todo el día"))
        } else if needsTime {
            parts.append(language.pick("Choose a time", "Elige la hora"))
        } else {
            parts.append(shown.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale)))
        }
        if let location = proposed.location { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    /// Why this card remembers it was used: the same message is drawn again
    /// every time the chat is opened.
    private var key: String {
        "\(proposed.title)|\(proposed.date)|\(proposed.time ?? "")"
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        added = AddEventCard.addedAt(key)
        if let proposedStart = proposed.start {
            start = proposed.time == nil
                ? Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: proposedStart) ?? proposedStart
                : proposedStart
        }
        allDay = false
        timeChosen = proposed.time != nil
        initialStart = start
    }

    private func add() async {
        working = true
        defer { working = false }
        problem = nil
        if !CalendarSync.hasAccess, let refused = await store.connectCalendar() {
            problem = refused
            return
        }
        do {
            let when = allDay ? Calendar.current.startOfDay(for: start) : start
            _ = try CalendarSync.add(
                title: proposed.title, start: when, allDay: allDay,
                minutes: proposed.minutes, location: proposed.location
            )
            added = when
            AddEventCard.remember(key, at: when)
            await store.syncCalendarNow()
        } catch {
            problem = language.pick("The event could not be added: ", "No se pudo añadir el evento: ") + error.localizedDescription
        }
    }

    private static let addedKey = "alice.calendar.added"

    private static func addedAt(_ key: String) -> Date? {
        (UserDefaults.standard.dictionary(forKey: addedKey)?[key] as? Double)
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private static let dismissedKey = "alice.calendar.dismissed"

    private static func dismissedBefore(_ key: String) -> Bool {
        UserDefaults.standard.dictionary(forKey: dismissedKey)?[key] != nil
    }

    private static func rememberDismissed(_ key: String) {
        var all = UserDefaults.standard.dictionary(forKey: dismissedKey) ?? [:]
        all[key] = Date().timeIntervalSinceReferenceDate
        // A handful of keys at most; cards are few and short-lived.
        if all.count > 200 { all = all.filter { ($0.value as? Double ?? 0) > Date().timeIntervalSinceReferenceDate - 90 * 86400 } }
        UserDefaults.standard.set(all, forKey: dismissedKey)
    }

    private static func remember(_ key: String, at date: Date) {
        var all = UserDefaults.standard.dictionary(forKey: addedKey) ?? [:]
        all[key] = date.timeIntervalSinceReferenceDate
        UserDefaults.standard.set(all, forKey: addedKey)
    }
}
