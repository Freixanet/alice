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
    @State private var pickerWidth: CGFloat = 0
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pickerWidth = $0 }
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                // A segmented Picker does not emit a selection change when its
                // already-selected segment is tapped. Chat still opens Today.
                if selected == .chat, pickerWidth > 0,
                   value.location.x >= 0, value.location.x < pickerWidth / 5 {
                    onOpenToday()
                }
            }
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 26,
                bottomTrailingRadius: 26,
                topTrailingRadius: 2
            )
        )
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .accessibilityIdentifier("home.experimentalMenu")
        .onAppear { selected = .chat }
        .onChange(of: selected) { _, section in
            switch section {
            case .chat: break
            case .today: onOpenToday()
            case .goals: onOpenDestination(.goals)
            case .feed: onOpenDestination(.feed)
            case .library: onOpenDestination(.library)
            }
        }
    }
}
