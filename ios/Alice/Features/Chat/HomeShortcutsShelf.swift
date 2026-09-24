import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Compact pins under the empty-home greeting, three across, the way pinned
/// agents sit on the Agents page.
struct HomeShortcutsShelf: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var draggedID: String?
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        let items = store.homeShortcuts
        VStack(spacing: 18) {
            ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items[start..<min(start + 3, items.count)]) { shortcut in
                        tile(shortcut)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("home.shortcuts")
    }

    private func tile(_ shortcut: HomeShortcut) -> some View {
        Button {
            store.openHomeShortcut(shortcut)
        } label: {
            VStack(spacing: 8) {
                icon(for: shortcut)
                Text(store.homeShortcutStyledLabel(shortcut))
                    .font(.caption.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 88, alignment: .top)
            }
            .frame(width: 96, alignment: .top)
            .contentShape(.rect)
            .contentShape(.contextMenuPreview, PortraitMenuShape(diameter: 52, gap: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.shortcut.\(shortcut.id)")
        .accessibilityLabel(store.homeShortcutLabel(shortcut))
        .contextMenu {
            Button("Remove from Home", systemImage: "house", role: .destructive) {
                store.removeHomeShortcut(shortcut.id)
            }
        }
        .onDrag {
            draggedID = shortcut.id
            return NSItemProvider(object: shortcut.id as NSString)
        } preview: {
            tilePreview(shortcut)
        }
        .onDrop(
            of: [UTType.text],
            delegate: HomeShortcutReorderDropDelegate(
                target: shortcut.id,
                peers: store.homeShortcuts.map(\.id),
                draggedID: $draggedID,
                move: { source, dest in
                    haptic.impactOccurred()
                    store.moveHomeShortcut(source, to: dest)
                }
            )
        )
    }

    @ViewBuilder
    private func icon(for shortcut: HomeShortcut) -> some View {
        if case let .bot(name) = shortcut.target {
            BotMarkView(mark: store.mark(for: name), size: 52, animated: false)
        } else {
            Image(systemName: shortcut.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .background(Palette.muted(scheme), in: .circle)
        }
    }

    private func tilePreview(_ shortcut: HomeShortcut) -> some View {
        VStack(spacing: 8) {
            icon(for: shortcut)
            Text(store.homeShortcutStyledLabel(shortcut))
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(width: 96)
        .padding(.vertical, 8)
    }
}

/// Add or take a pin off home, from a context menu.
struct AddToHomeButton: View {
    @Environment(AppStore.self) private var store
    let target: HomeShortcut.Target
    let label: String
    var symbol: String

    var body: some View {
        if store.hasHomeShortcut(matching: target) {
            Button("Remove from Home", systemImage: "house") {
                store.removeHomeShortcut(matching: target)
            }
        } else {
            Button("Add to Home", systemImage: "house") {
                store.addHomeShortcut(HomeShortcut(label: label, symbol: symbol, target: target))
            }
        }
    }
}

/// The same drop-to-swap the Agents shelf uses: entering a neighbour is the
/// move, so the row follows the finger instead of waiting for a drop.
private struct HomeShortcutReorderDropDelegate: DropDelegate {
    let target: String
    let peers: [String]
    @Binding var draggedID: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let source = draggedID, source != target, peers.contains(source) else { return }
        move(source, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}
