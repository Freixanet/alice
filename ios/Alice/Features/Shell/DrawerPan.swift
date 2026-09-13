import SwiftUI
import UIKit

/// A horizontal pan that works anywhere on screen without fighting scrolling.
///
/// SwiftUI's `DragGesture` cannot express "only if this drag is horizontal".
/// It starts tracking the moment the finger moves, so one laid over the
/// transcript claims part of every vertical scroll, and the drawer creeps
/// open while the reader is only moving down the conversation. That is why
/// the open gesture used to live on a 20pt strip at the screen's edge.
///
/// UIKit can decide at the instant the gesture would begin, from its
/// velocity, and then run *alongside* the scroll view rather than stealing
/// from it. A pan that starts out mostly sideways drives the drawer; one that
/// starts out mostly vertical is never claimed at all, and scrolling behaves
/// as if this did not exist.
///
/// The recogniser is attached to the enclosing view controller's view, not to
/// the window, so anything presented above the chat — the model picker, a
/// share sheet — keeps its own gestures.
struct DrawerPan: UIViewRepresentable {
    /// Given the pan's velocity, whether this drag should drive the drawer.
    let shouldBegin: (CGPoint) -> Bool
    let onChange: (CGFloat) -> Void
    /// Translation and predicted end translation, both on the x axis.
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = AnchorView()
        // Purely an anchor: it must never take a touch of its own, or it
        // would sit between the reader and the chat underneath it.
        view.isUserInteractionEnabled = false
        view.onEnterHierarchy = { [coordinator = context.coordinator] host in
            coordinator.attach(near: host)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldBegin: shouldBegin, onChange: onChange, onEnd: onEnd)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: (CGPoint) -> Bool
        var onChange: (CGFloat) -> Void
        var onEnd: (CGFloat, CGFloat) -> Void

        private weak var host: UIView?
        private var pan: UIPanGestureRecognizer?

        init(
            shouldBegin: @escaping (CGPoint) -> Bool,
            onChange: @escaping (CGFloat) -> Void,
            onEnd: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.onChange = onChange
            self.onEnd = onEnd
        }

        func attach(near anchor: UIView) {
            guard pan == nil, let host = anchor.owningControllerView else { return }
            let pan = UIPanGestureRecognizer(self, action: #selector(handle))
            pan.delegate = self
            // Buttons, links and text selection all keep working: this watches
            // the touch, it does not swallow it.
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            host.addGestureRecognizer(pan)
            self.host = host
            self.pan = pan
        }

        func detach() {
            if let pan { host?.removeGestureRecognizer(pan) }
            pan = nil
            host = nil
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            let x = pan.translation(in: pan.view).x
            switch pan.state {
            case .changed:
                onChange(x)
            case .ended, .cancelled, .failed:
                // A flick should finish the drawer even from a short drag, so
                // hand back where the movement was heading, not just where the
                // finger stopped. 0.2s is roughly the coast of a UIKit flick.
                onEnd(x, x + pan.velocity(in: pan.view).x * 0.2)
            default:
                break
            }
        }

        nonisolated func gestureRecognizerShouldBegin(
            _ recognizer: UIGestureRecognizer
        ) -> Bool {
            MainActor.assumeIsolated {
                guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
                let velocity = pan.velocity(in: pan.view)
                // A real swipe has intent and speed. Without a floor here, the
                // few pixels a thumb naturally drifts while tapping a glass
                // button can promote this full-screen recogniser to `.began`
                // and make SwiftUI's Button tap lose on device. XCUI taps are
                // perfectly still, which is why that failure escaped the test.
                guard abs(velocity.x) >= 80 else { return false }
                return shouldBegin(velocity)
            }
        }

        nonisolated func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            MainActor.assumeIsolated {
                // Screen-wide navigation must never compete with a control.
                // SwiftUI commonly exposes the accessibility trait on a
                // hosting descendant rather than a UIControl, so honour both.
                var view: UIView? = touch.view
                while let current = view, current !== host {
                    if current is UIControl
                        || current is UITextField
                        || current is UITextView
                        || current.accessibilityTraits.contains(.button)
                        || current.accessibilityTraits.contains(.link) {
                        return false
                    }
                    view = current.superview
                }
                return true
            }
        }

        nonisolated func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// Reports the moment it has a superview, which is the first point at
    /// which the enclosing controller can be found.
    private final class AnchorView: UIView {
        var onEnterHierarchy: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onEnterHierarchy?(self) }
        }
    }
}

private extension UIView {
    /// The view of the nearest enclosing controller — the full-screen view the
    /// chat is laid out in, and the right scope for a screen-wide gesture.
    var owningControllerView: UIView? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller.view }
            responder = next
        }
        return superview
    }
}

private extension UIPanGestureRecognizer {
    convenience init(_ target: Any, action: Selector) {
        self.init(target: target, action: action)
    }
}
