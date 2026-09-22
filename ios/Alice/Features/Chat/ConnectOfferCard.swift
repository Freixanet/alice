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
                Label("Read-only. Your events go only to your own Hermes.", systemImage: "lock")
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
