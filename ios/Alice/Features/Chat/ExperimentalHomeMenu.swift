import SwiftUI

/// Opt-in presentation only; both interfaces share chats, drafts and navigation.
enum HomeInterface: String {
    case current, experimental
    static let storageKey = "alice.developer.homeInterface"
}

struct ExperimentalHomeMenu: View {
    private enum Section: String {
        case chat, today, goals, feed, library
    }

    @Namespace private var glassSelection
    @State private var selected: Section = .chat
    let onOpenChat: () -> Void
    let onOpenToday: () -> Void
    let onOpenDestination: (AliceDestination.Target) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 0) {
                item(.chat, symbol: "bubble.left", label: "Chat", action: onOpenChat)
                item(.today, symbol: "sun.max", label: "Today", action: onOpenToday)
                item(.goals, symbol: "scope", label: "Goals") { onOpenDestination(.goals) }
                item(.feed, symbol: "rectangle.stack", label: "Feed") { onOpenDestination(.feed) }
                item(.library, symbol: "photo.on.rectangle", label: "Library") {
                    onOpenDestination(.library)
                }
            }
            .padding(6)
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityIdentifier("home.experimentalMenu")
    }

    private func item(
        _ section: Section, symbol: String, label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { selected = section }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(.rect)
                .background {
                    if selected == section {
                        Color.clear
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("home-selection", in: glassSelection)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected == section ? .isSelected : [])
        .accessibilityIdentifier("home.menu.\(section.rawValue)")
    }
}
