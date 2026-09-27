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

    @Namespace private var selectionGlass
    @State private var selected: Section = .chat
    let onOpenToday: () -> Void
    let onOpenDestination: (AliceDestination.Target) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Section.allCases, id: \.self) { section in
                        item(section)
                    }
                }
                .padding(6)
                .contentShape(.rect)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let section = section(at: value.location.x, width: geometry.size.width)
                            if selected != section {
                                withAnimation(.snappy(duration: 0.18)) { selected = section }
                            }
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            activate(section(at: value.location.x, width: geometry.size.width))
                        }
                )
            }
            .frame(height: 56)
        }
        .glassEffect(
            .regular.interactive(),
            in: UnevenRoundedRectangle(
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
    }

    private func item(_ section: Section) -> some View {
        Button {
            activate(section)
        } label: {
            Image(systemName: section.symbol)
                .font(.system(size: 19, weight: selected == section ? .semibold : .medium))
                .foregroundStyle(selected == section ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if selected == section {
                        Color.clear
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("home-selection", in: selectionGlass)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.label)
        .accessibilityAddTraits(selected == section ? .isSelected : [])
        .accessibilityIdentifier("home.menu.\(section.rawValue)")
    }

    private func section(at x: CGFloat, width: CGFloat) -> Section {
        let itemWidth = max((width - 12) / CGFloat(Section.allCases.count), 1)
        let index = min(max(Int(floor((x - 6) / itemWidth)), 0), Section.allCases.count - 1)
        return Section.allCases[index]
    }

    private func activate(_ section: Section) {
        withAnimation(.snappy(duration: 0.18)) { selected = section }
        switch section {
        case .chat, .today: onOpenToday()
        case .goals: onOpenDestination(.goals)
        case .feed: onOpenDestination(.feed)
        case .library: onOpenDestination(.library)
        }
    }
}
