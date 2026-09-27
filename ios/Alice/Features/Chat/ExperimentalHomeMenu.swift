import SwiftUI

/// Opt-in presentation only; both interfaces share chats, drafts and navigation.
enum HomeInterface: String {
    case current, experimental
    static let storageKey = "alice.developer.homeInterface"
}

struct ExperimentalHomeMenu: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onOpenChats: () -> Void
    let onOpenDestination: (AliceDestination.Target) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    items
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("home.menu.scroll")
            } else {
                items
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var items: some View {
        HStack(spacing: 0) {
            item("Chats", symbol: "bubble.left.and.bubble.right", id: "chats", action: onOpenChats)
            item("Agents", symbol: "person.2", id: "agents") { onOpenDestination(.bots) }
            item("Notes", symbol: "note.text", id: "notes") { onOpenDestination(.notes) }
            item("Agenda", symbol: "calendar", id: "agenda") { onOpenDestination(.agenda) }
        }
    }

    private func item(
        _ title: LocalizedStringKey, symbol: String, id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 18 : 4)
            .padding(.vertical, 4)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
        .accessibilityIdentifier("home.menu.\(id)")
    }
}
