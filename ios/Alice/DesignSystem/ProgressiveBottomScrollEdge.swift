import SwiftUI
import UIKit

/// A viewport band ending at the physical bottom or the keyboard, underneath
/// the composer. Unlike a composer background it never starts 64pt above it.
struct ProgressiveBottomScrollEdge: UIViewRepresentable {
    static var usesFallback: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }
    static let height: CGFloat = 84

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.band.configure(background: UIColor(Palette.background(scheme)),
                              reduceTransparency: reduceTransparency)
        anchor.enabled = Self.usesFallback
        anchor.attachIfNeeded()
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) { anchor.detach() }

    final class Anchor: UIView {
        let band = Band()
        var enabled = false
        private weak var host: UIView?
        private var constraints: [NSLayoutConstraint] = []
        private var previousKeyboardSafeArea = true

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attachIfNeeded() }
        }

        func attachIfNeeded() {
            guard enabled else { detach(); return }
            guard window != nil, host == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView, let parent = scroll.superview {
                    // The content anchor identifies its own scroll once. The
                    // band is a sibling, so it cannot move with contentOffset.
                    host = parent
                    parent.addSubview(band)
                    band.translatesAutoresizingMaskIntoConstraints = false
                    let keyboard = parent.keyboardLayoutGuide
                    previousKeyboardSafeArea = keyboard.usesBottomSafeArea
                    keyboard.usesBottomSafeArea = false
                    constraints = [
                        band.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
                        band.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
                        band.bottomAnchor.constraint(equalTo: keyboard.topAnchor),
                        band.heightAnchor.constraint(equalToConstant: ProgressiveBottomScrollEdge.height)
                    ]
                    NSLayoutConstraint.activate(constraints)
                    #if DEBUG
                    ChatScrollEdgeCapture.schedule(scroll: scroll, band: band)
                    #endif
                    return
                }
                ancestor = view.superview
            }
        }

        func detach() {
            NSLayoutConstraint.deactivate(constraints)
            constraints = []
            host?.keyboardLayoutGuide.usesBottomSafeArea = previousKeyboardSafeArea
            band.removeFromSuperview()
            host = nil
        }
    }

    final class Band: UIView {
        private let blur = UIVisualEffectView()
        private let blurMask = CAGradientLayer()
        private let wash = CAGradientLayer()
        private var blurEnabled = false
        private var currentBackground: UIColor?
        private let stops: [NSNumber] = [0, 0.12, 0.28, 0.46, 0.72, 1]

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            blur.isUserInteractionEnabled = false
            addSubview(blur)
            blur.layer.mask = blurMask
            layer.addSublayer(wash)
            for gradient in [blurMask, wash] {
                gradient.startPoint = CGPoint(x: 0.5, y: 0)
                gradient.endPoint = CGPoint(x: 0.5, y: 1)
                gradient.locations = stops
            }
            blurMask.colors = [0.0, 0.08, 0.28, 0.58, 0.85, 1.0].map {
                UIColor.white.withAlphaComponent($0).cgColor
            }
        }

        required init?(coder: NSCoder) { nil }

        func configure(background: UIColor, reduceTransparency: Bool) {
            let enabled = !reduceTransparency
            if blurEnabled != enabled {
                blurEnabled = enabled
                blur.effect = enabled ? UIBlurEffect(style: .systemThinMaterial) : nil
            }
            if currentBackground != background {
                currentBackground = background
                wash.colors = [0.0, 0.01, 0.05, 0.18, 0.45, 0.90].map {
                    background.withAlphaComponent($0).cgColor
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            blur.frame = bounds
            blurMask.frame = bounds
            wash.frame = bounds
            CATransaction.commit()
        }
    }
}
