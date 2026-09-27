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

    @State private var selected: Section?
    let onOpenToday: () -> Void
    let onOpenDestination: (AliceDestination.Target) -> Void

    var body: some View {
        Picker("Home", selection: $selected) {
            ForEach(Section.allCases, id: \.self) { section in
                Label(section.label, systemImage: section.symbol)
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("home.menu.\(section.rawValue)")
                    .tag(section as Section?)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .accessibilityIdentifier("home.experimentalMenu")
        .onChange(of: selected) { _, section in
            guard let section else { return }
            switch section {
            case .chat, .today: onOpenToday()
            case .goals: onOpenDestination(.goals)
            case .feed: onOpenDestination(.feed)
            case .library: onOpenDestination(.library)
            }
            // This picker launches destinations. Clear its selection so the same
            // icon can be chosen again after returning to Home.
            selected = nil
        }
    }
}
