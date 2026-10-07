import SwiftUI
import UIKit

/// Swipe one of Alice's replies to the right to answer that reply, as in Messages: it follows the
/// finger, an arrow comes in on its left, a tap of haptics says "let go now", the rest of the chat
/// blurs behind it, and on release the keyboard opens with the reply quoted above it.
struct ReplySwipe: ViewModifier {
    let message: Message
    let author: String
    let enabled: Bool

    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var armed = false
    @State private var width: CGFloat = 0

    /// How far the reply travels before letting go answers it, and the most it ever moves.
    static let threshold: CGFloat = 44
    /// The last moment a finger came down on a reply. A swipe right that starts there is this
    /// reply's, not the drawer's (`RootView`).
    @MainActor static var touchedAt = Date.distantPast

    private var progress: CGFloat { min(1, offset / Self.threshold) }

    /// Shrunk by as much as it moved, from its leading edge: its right side never goes further
    /// right than it was, so a wide reply never reaches the edge of the screen.
    private var scale: CGFloat { width > 0 ? (width - offset) / width : 1 }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .scaleEffect(scale, anchor: .leading)
            .offset(x: offset)
            .overlay(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .scaleEffect(armed ? 1 : 0.6 + 0.3 * progress)
                    .opacity(progress)
                    // Comes in from behind the screen's edge, a step ahead of the reply.
                    .offset(x: offset / 2 - 20)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .gesture(ReplyPan(
                enabled: enabled,
                onTouch: { Self.touchedAt = .now },
                onChange: follow,
                onEnd: release
            ))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
            .accessibilityActions {
                if enabled { Button("Reply") { answer() } }
            }
    }

    private func follow(_ translation: CGFloat) {
        let x = max(0, translation)
        // Follows the finger up to the threshold and stops there.
        offset = min(x, Self.threshold)
        if x > 0, store.replySwipingID != message.id {
            withMotion(.easeOut(duration: 0.15)) { store.replySwipingID = message.id }
        }
        let nowArmed = x >= Self.threshold
        if nowArmed != armed { armed = nowArmed }
    }

    private func release(_ translation: CGFloat, _: CGFloat) {
        let answering = armed
        withMotion(.snappy(duration: 0.2)) {
            offset = 0
            if answering { answer() }
            store.replySwipingID = nil
        }
        armed = false
    }

    private func answer() {
        store.replyingTo = ReplyQuote(messageID: message.id, author: author, content: message.content)
    }
}

/// Only a pan that starts out rightward and sideways: scrolling the chat is never taken.
private struct ReplyPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let onTouch: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(onTouch: onTouch)
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = enabled
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.isEnabled = enabled
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .began, .changed:
            onChange(translation)
        case .ended, .cancelled, .failed:
            onEnd(translation, translation + pan.velocity(in: pan.view).x * 0.15)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onTouch: () -> Void
        init(onTouch: @escaping () -> Void) { self.onTouch = onTouch }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            onTouch()
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.2
        }
    }
}

extension View {
    /// Off for the person's own messages and a reply still being written; the view keeps its
    /// identity either way.
    func replySwipe(_ message: Message, author: String, enabled: Bool) -> some View {
        modifier(ReplySwipe(message: message, author: author, enabled: enabled))
    }
}

/// The reply a sent message answers, above it and quieter than it, as Messages shows one.
struct QuotedReply: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label("You replied", systemImage: "arrowshape.turn.up.left.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.card(scheme).opacity(0.6), in: .rect(cornerRadius: 16))
        }
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}
