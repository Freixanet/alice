import SwiftUI
import UIKit

struct MessageReplyInteraction: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: Message
    @State private var offset: CGFloat = 0
    @State private var crossed = false

    private var eligible: Bool {
        message.role == .assistant && !message.pending && !message.content.isEmpty && !store.activeIsRecoveredHistory
    }
    private var selected: Bool { store.replySpotlightID == message.id }

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier("message.\(message.id)")
            .padding(.leading, selected ? 32 : 0)
            .offset(x: offset)
            .blur(radius: store.replySpotlightID != nil && !selected ? 4 : 0)
            .overlay(alignment: .leading) {
                if eligible && (offset > 0 || selected) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .offset(x: 0)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if eligible {
                    MessageReplyPan { translation, ended, cancelled in
                        let distance = max(0, min(translation, 80))
                        if !ended {
                            offset = distance
                            if distance > 0 { store.replyGestureMessageID = message.id }
                            if !crossed && MessageReplySwipe.completes(translation: translation) {
                                crossed = true
                                Haptic.selection.play()
                            }
                        } else {
                            if !cancelled && MessageReplySwipe.completes(translation: translation) {
                                store.beginReply(to: message)
                            }
                            if store.replyGestureMessageID == message.id { store.replyGestureMessageID = nil }
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { offset = 0 }
                            crossed = false
                        }
                    }
                }
            }
            .accessibilityAction(named: Text("Reply")) {
                if eligible { Haptic.selection.play(); store.beginReply(to: message) }
            }
    }
}

/// The drawer yields only within an eligible assistant row. Other directions and controls keep navigation.
@MainActor
final class MessageReplyRegions {
    static let shared = MessageReplyRegions()
    private final class WeakAnchor {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }
    private var anchors: [UUID: WeakAnchor] = [:]
    func add(_ anchor: UIView, id: UUID) { anchors[id] = WeakAnchor(anchor) }
    func remove(_ id: UUID) { anchors[id] = nil }
    func contains(_ point: CGPoint, in host: UIView) -> Bool {
        anchors.values.contains { entry in
            guard let view = entry.view, view.window != nil, view.isDescendant(of: host) else { return false }
            return view.convert(view.bounds, to: host).contains(point)
        }
    }
}

private struct MessageReplyPan: UIViewRepresentable {
    var changed: (CGFloat, Bool, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(changed) }
    func makeUIView(context: Context) -> UIView {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.entered = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return anchor
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.changed = changed }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.detach() }

    private final class Anchor: UIView {
        var entered: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { entered?(self) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let id = UUID()
        weak var anchor: UIView?
        weak var host: UIView?
        var pan: UIPanGestureRecognizer?
        var changed: (CGFloat, Bool, Bool) -> Void
        init(_ changed: @escaping (CGFloat, Bool, Bool) -> Void) { self.changed = changed }
        func attach(_ anchor: UIView) {
            guard pan == nil else { return }
            var responder: UIResponder? = anchor
            while responder != nil && !(responder is UIViewController) { responder = responder?.next }
            guard let host = (responder as? UIViewController)?.view else { return }
            self.anchor = anchor
            self.host = host
            let pan = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = true
            host.addGestureRecognizer(pan)
            self.pan = pan
            MessageReplyRegions.shared.add(anchor, id: id)
        }
        func detach() {
            if let pan { host?.removeGestureRecognizer(pan) }
            MessageReplyRegions.shared.remove(id)
            changed(0, true, true)
            pan = nil
        }
        @objc func moved(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began, .changed: changed(pan.translation(in: host).x, false, false)
            case .ended: changed(pan.translation(in: host).x, true, false)
            case .cancelled, .failed: changed(0, true, true)
            default: break
            }
        }
        nonisolated func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
                return MessageReplySwipe.starts(velocity: pan.velocity(in: host))
            }
        }
        nonisolated func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            MainActor.assumeIsolated {
                guard let anchor, let host, anchor.convert(anchor.bounds, to: host).contains(touch.location(in: host)) else { return false }
                var view = touch.view
                while let current = view, current !== host {
                    if current is UIControl || current.accessibilityTraits.contains(.button)
                        || current.accessibilityTraits.contains(.link) { return false }
                    if let text = current as? UITextView, text.selectedRange.length > 0 { return false }
                    if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                    view = current.superview
                }
                return true
            }
        }
        nonisolated func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}

/// The selected message remains visible in the transcript; the composer only names its recipient.
struct MessageReplyRecipient: View {
    let reply: MessageReply
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
            Text("Replying to \(reply.author)").lineLimit(1)
            Spacer(minLength: 0)
            Button(action: cancel) { Image(systemName: "xmark") }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Cancel reply")
                .accessibilityIdentifier("composer.cancelReply")
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}

struct MessageReplyQuote: View {
    @Environment(\.colorScheme) private var scheme
    let reply: MessageReply
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Label("You replied to \(reply.author)", systemImage: "arrowshape.turn.up.left.fill")
                .font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: reply.content)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(5).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Palette.card(scheme), in: .rect(cornerRadius: 18))
        }
        .padding(.leading, 32)
        .fixedSize(horizontal: false, vertical: true)
    }
}
