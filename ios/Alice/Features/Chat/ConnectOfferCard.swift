import SwiftUI

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
    let service: String

    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect your calendar")
                        .font(.headline)
                    Text("So your agents can plan around your day: what you have, when you are free, what is coming up.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch store.calendarLink {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.success(scheme))
            case .declined:
                Text("Not now. You can connect it any time in Settings › Connections.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .notConnected, .unknown:
                HStack(spacing: 10) {
                    Button {
                        Task { await connect() }
                    } label: {
                        Group {
                            if working {
                                ProgressView()
                            } else {
                                Label("Connect", systemImage: "calendar.badge.plus")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(accent)

                    Button("Not now") {
                        Task { await decline() }
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.primary)
                }
                .disabled(working || store.isSending)
                Label("Your events go only to your own Hermes. Alice adds only what you confirm.", systemImage: "lock")
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
            store.sendQuickReply("Listo, ya he conectado el calendario.")
        }
    }

    private func decline() async {
        await store.declineCalendar()
        store.sendQuickReply("Ahora no.")
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
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .foregroundStyle(store.accent.primary(scheme))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar")
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            return "Connected · updated \(updatedAt.formatted(.relative(presentation: .named)))"
        case .declined: return "Not connected — agents won’t offer it"
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
    let proposed: RichCalendarEvent

    @State private var start = Date()
    @State private var allDay = false
    @State private var prepared = false
    @State private var working = false
    @State private var problem: String?
    @State private var added: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: added == nil ? "calendar.badge.plus" : "calendar.badge.checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposed.title)
                        .font(.headline)
                    if let location = proposed.location {
                        Label(location, systemImage: "mappin")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let added {
                HStack {
                    Label("Added to your calendar", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.success(scheme))
                    Spacer()
                    Button("Open") {
                        if let url = URL(string: "calshow:\(added.timeIntervalSinceReferenceDate)") {
                            openURL(url)
                        }
                    }
                    .font(.subheadline)
                }
            } else {
                VStack(spacing: 8) {
                    DatePicker(
                        "When", selection: $start,
                        displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]
                    )
                    Toggle("All day", isOn: $allDay)
                }
                .font(.subheadline)

                Button {
                    Task { await add() }
                } label: {
                    Group {
                        if working {
                            ProgressView()
                        } else {
                            Label("Add to Calendar", systemImage: "plus")
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

                Label(
                    allDay ? "With a reminder that morning. Added only when you tap." : "With a reminder an hour before. Added only when you tap.",
                    systemImage: "bell"
                )
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
        .animation(.snappy(duration: 0.25), value: added)
        .onAppear(perform: prepare)
    }

    private var accent: Color { store.accent.primary(scheme) }

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
            problem = "The event could not be added: \(error.localizedDescription)"
        }
    }

    private static let addedKey = "alice.calendar.added"

    private static func addedAt(_ key: String) -> Date? {
        (UserDefaults.standard.dictionary(forKey: addedKey)?[key] as? Double)
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private static func remember(_ key: String, at date: Date) {
        var all = UserDefaults.standard.dictionary(forKey: addedKey) ?? [:]
        all[key] = date.timeIntervalSinceReferenceDate
        UserDefaults.standard.set(all, forKey: addedKey)
    }
}
