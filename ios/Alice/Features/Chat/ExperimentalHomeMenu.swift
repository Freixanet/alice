import SwiftUI

/// Opt-in presentation only; both interfaces share chats, drafts and navigation.
enum HomeInterface: String {
    case current, experimental
    static let storageKey = "alice.developer.homeInterface"
}

struct ExperimentalHomeMenu: View {
    private enum Section: String, CaseIterable {
        case chat, today, goals, feed, library

        var symbol: String {
            switch self {
            case .chat: "bubble.left"
            case .today: "sun.max"
            case .goals: "scope"
            case .feed: "rectangle.stack"
            case .library: "photo.on.rectangle"
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .chat: "Chat"
            case .today: "Today"
            case .goals: "Goals"
            case .feed: "Feed"
            case .library: "Library"
            }
        }
    }

    @State private var selected: Section = .chat
    let onOpenToday: () -> Void
    let onOpenDestination: (AliceDestination.Target) -> Void

    var body: some View {
        Picker("Home", selection: $selected) {
            ForEach(Section.allCases, id: \.self) { section in
                Label(section.label, systemImage: section.symbol)
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("home.menu.\(section.rawValue)")
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityIdentifier("home.experimentalMenu")
        .onChange(of: selected) { _, section in
            switch section {
            case .chat: break // Home is already the chat surface.
            case .today: onOpenToday()
            case .goals: onOpenDestination(.goals)
            case .feed: onOpenDestination(.feed)
            case .library: onOpenDestination(.library)
            }
        }
    }
}
