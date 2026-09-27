import SwiftUI

/// Opt-in presentation only; both interfaces share chats, drafts and navigation.
enum HomeInterface: String {
    case current, experimental
    static let storageKey = "alice.developer.homeInterface"
}

struct ExperimentalHomeMenu: View {
    private enum Section: String, CaseIterable {
        case chat, today, goals, feed, library
    }

    @Namespace private var glassSelection
    @State private var selected: Section = .chat
    let onOpenChat: () -> Void
    let onOpenToday: () -> Void
    let onOpenDestination: (AliceDestination.Target) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    item(.chat, symbol: "bubble.left", label: "Chat")
                    item(.today, symbol: "sun.max", label: "Today")
                    item(.goals, symbol: "scope", label: "Goals")
                    item(.feed, symbol: "rectangle.stack", label: "Feed")
                    item(.library, symbol: "photo.on.rectangle", label: "Library")
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
            .frame(height: 60)
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityIdentifier("home.experimentalMenu")
    }

    private func item(
        _ section: Section, symbol: String, label: LocalizedStringKey
    ) -> some View {
        Button {
            activate(section)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: selected == section ? .semibold : .medium))
                .foregroundStyle(selected == section ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(.rect)
                .background {
                    if selected == section {
                        Color.clear
                            .glassEffect(.regular.tint(.black.opacity(0.72)), in: .capsule)
                            .glassEffectID("home-selection", in: glassSelection)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        case .chat: onOpenChat()
        case .today: onOpenToday()
        case .goals: onOpenDestination(.goals)
        case .feed: onOpenDestination(.feed)
        case .library: onOpenDestination(.library)
        }
    }
}
