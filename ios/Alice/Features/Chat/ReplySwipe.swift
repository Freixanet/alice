import SwiftUI
import UIKit

/// Swipe one of Alice's replies to the right to answer that reply, as in Messages: it follows the
/// finger up to a stop, an arrow comes in on its left, a haptic says "let go now", the rest of the
/// chat blurs behind it, and on release the keyboard opens and the reply rests above the composer.
///
/// Everything the swipe changes is drawn by modifiers on single rows (`ReplyFocus`, `ReplyHold`,
/// `ReplyBackdrop`), so the transcript itself is never rebuilt while the finger moves.
struct ReplySwipe: ViewModifier {
    let message: Message
    let author: String
    let enabled: Bool

    @Environment(AppStore.self) private var store
    @State private var offset: CGFloat = 0
    @State private var armed = false

    /// How far the reply travels, and where letting go answers it.
    static let travel: CGFloat = 40
    /// The most a reply gives past `travel`, however far the finger goes.
    static let give: CGFloat = 18
    /// The last moment a finger came down on a reply. A swipe right that starts there is this
    /// reply's, not the drawer's (`RootView`).
    @MainActor static var touchedAt = Date.distantPast

    private var progress: CGFloat { min(1, offset / Self.travel) }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .overlay(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .scaleEffect(armed ? 1 : 0.7)
                    .animation(.snappy(duration: 0.15), value: armed)
                    .opacity(progress)
                    .offset(x: -14 + offset / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .gesture(ReplyPan(
                enabled: enabled,
                onTouch: { Self.touchedAt = .now },
                onBegin: begin,
                onChange: follow,
                onEnd: release
            ))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
            .accessibilityActions {
                if enabled { Button("Reply") { answer() } }
            }
    }

    private func begin() {}

    private func follow(_ translation: CGFloat) {
        let x = max(0, translation)
        // Free up to the haptic; past it the reply resists, giving at most a little more.
        offset = x <= Self.travel ? x : Self.travel + Self.give * (1 - exp(-(x - Self.travel) / 70))
        let nowArmed = x >= Self.travel
        if nowArmed != armed { armed = nowArmed }
    }

    private func release(_ translation: CGFloat) {
        let answering = armed
        armed = false
        // Back to its place on a soft spring; the blur and the keyboard come in with it.
        withMotion(.spring(response: 0.32, dampingFraction: 0.82)) {
            offset = 0
            if answering { answer() }
        }
    }

    private func answer() {
        store.replyingTo = ReplyQuote(messageID: message.id, author: author, content: message.content)
    }
}

/// Every row's part in a reply being swiped or answered: the others blur and let go of it on a
/// tap; the one answered comes down to rest just above the composer, drawn over the rest.
struct ReplyFocus: ViewModifier {
    let messageID: String
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        let focus = store.replyFocusID
        let behind = focus != nil && focus != messageID
        // Read only by the row being answered, so the keyboard moving redraws that row alone.
        let rest: CGFloat? = store.replyingTo?.messageID == messageID ? store.composerTop - 14 : nil
        content
            .visualEffect { effect, proxy in
                effect
                    .blur(radius: behind ? 10 : 0)
                    .opacity(behind ? 0.35 : 1)
                    .offset(y: rest.map { $0 - proxy.frame(in: .global).maxY } ?? 0)
            }
            .zIndex(focus == messageID ? 1 : 0)
            .overlay {
                if behind {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { withMotion(.snappy(duration: 0.22)) { store.replyingTo = nil } }
                }
            }
    }
}

/// The chat holds still while a reply is in front.
struct ReplyHold: ViewModifier {
    @Environment(AppStore.self) private var store
    func body(content: Content) -> some View {
        content.scrollDisabled(store.replyFocusID != nil)
    }
}

/// Gone while a reply is in front: for controls with nothing to do then, like the jump to the end.
struct ReplyHidden: ViewModifier {
    @Environment(AppStore.self) private var store
    func body(content: Content) -> some View {
        let hidden = store.replyFocusID != nil
        content
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

/// The chat's header blurs with the rest behind a reply in front; a tap on it lets go.
struct ReplyBackdrop: ViewModifier {
    @Environment(AppStore.self) private var store
    func body(content: Content) -> some View {
        let behind = store.replyFocusID != nil
        content
            .visualEffect { effect, _ in effect.blur(radius: behind ? 10 : 0).opacity(behind ? 0.35 : 1) }
            .allowsHitTesting(!behind)
            .overlay {
                if behind {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { withMotion(.snappy(duration: 0.22)) { store.replyingTo = nil } }
                }
            }
    }
}

/// Only a pan that starts out rightward and sideways. It runs alongside the chat's scroll and,
/// the moment it begins, takes the touch from it, so the chat never drifts under a swipe.
private struct ReplyPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let onTouch: () -> Void
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(onTouch: onTouch)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began:
            // Measured from here, so the reply does not jump by the distance it took to begin.
            pan.setTranslation(.zero, in: pan.view)
            context.coordinator.stopScrolling(from: pan.view)
            onBegin()
        case .changed:
            onChange(pan.translation(in: pan.view).x)
        case .ended, .cancelled, .failed:
            onEnd(pan.translation(in: pan.view).x)
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
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.3
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }

        /// Cancels the enclosing scroll view's pan: turning it off and on ends its touch.
        func stopScrolling(from view: UIView?) {
            var current = view
            while let next = current {
                if let scroll = next as? UIScrollView {
                    scroll.panGestureRecognizer.isEnabled = false
                    scroll.panGestureRecognizer.isEnabled = true
                    return
                }
                current = next.superview
            }
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
