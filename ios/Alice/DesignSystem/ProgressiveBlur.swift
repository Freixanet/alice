// Adapted from expo-backdrop's ProgressiveBlurView, BlurEffectView and
// ScrollBlurMonitor (https://github.com/rit3zh/expo-backdrop).
// MIT License, Copyright (c) 2026 Ritesh. Permission is hereby granted, free
// of charge, to any person obtaining a copy of this software and associated
// documentation files, to deal in the Software without restriction, subject
// to including this notice. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT
// WARRANTY OF ANY KIND.

import SwiftUI
import UIKit

/// A blur that deepens towards one edge, over whatever scrolls behind it —
/// where the transcript passes under the header and the composer, or the
/// drawer's list under its own edges.
///
/// Public API only: a system material held part-way on (a paused property
/// animator), masked by an eased gradient so it rises from nothing, with a
/// wash of the page colour rising to the edge on top so text there fades
/// rather than smears. It stays out of sight until content is actually
/// under its edge, and while the scroll view behind flies past, it trades
/// the blur for a plain gradient: a moving blur costs frames for nothing.
struct ProgressiveBlur: UIViewRepresentable {
    enum Edge { case top, bottom }

    var edge: Edge
    /// Strength at the blurred edge, 0–1.
    var intensity: CGFloat = 0.5
    /// The page colour: the wash, and the gradient used while scrolling fast.
    var wash: Color
    /// Share of the height, from the far side, before the blur starts to rise.
    var startOffset: CGFloat = 0

    func makeUIView(context: Context) -> ProgressiveBlurUIView {
        let view = ProgressiveBlurUIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProgressiveBlurUIView, context: Context) {
        view.configure(edge: edge, intensity: intensity, wash: UIColor(wash), startOffset: startOffset)
    }
}

@MainActor
final class ProgressiveBlurUIView: UIView {
    private static let fadeSamples = 5
    private static let blurScale: CGFloat = 1.25
    private static let blurRampShare: CGFloat = 0.6
    private static let coverageFadeDistance: CGFloat = 24
    private static let washOpacity: CGFloat = 0.85

    private let blurContainer = UIView()
    private let maskedBlur = UIView()
    private let effectView = PartialBlurView()
    private let blurMask = EdgeGradientView()
    private let tintWash = EdgeGradientView()
    private let fallbackGradient = EdgeGradientView()
    private let monitor = ScrollSpeedMonitor()

    private var edge: ProgressiveBlur.Edge = .top
    private var strength: CGFloat = 0.5
    private var wash: UIColor = .systemBackground
    private var startOffset: CGFloat = 0
    private var liveBlurAmount: CGFloat = 1
    private var scrollViewCheck: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        blurContainer.isUserInteractionEnabled = false
        blurContainer.layer.allowsGroupOpacity = false
        maskedBlur.addSubview(effectView)
        maskedBlur.layer.mask = blurMask.layer
        blurContainer.addSubview(maskedBlur)
        blurContainer.addSubview(tintWash)
        addSubview(blurContainer)
        fallbackGradient.isHidden = true
        addSubview(fallbackGradient)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.updateGradients()
        }
        monitor.onChange = { [weak self] in self?.updateVisibility() }
        monitor.onBlurAmount = { [weak self] amount in
            self?.liveBlurAmount = amount
            self?.updateVisibility()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            scrollViewCheck?.invalidate()
            monitor.stop()
        }
    }

    func configure(edge: ProgressiveBlur.Edge, intensity: CGFloat, wash: UIColor, startOffset: CGFloat) {
        let changed = edge != self.edge || intensity != strength || wash != self.wash || startOffset != self.startOffset
        self.edge = edge
        strength = max(0, min(1, intensity))
        self.wash = wash
        self.startOffset = max(0, min(1, startOffset))
        effectView.intensity = min(1, strength * Self.blurScale)
        if changed {
            updateGradients()
            updateVisibility()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [blurContainer, maskedBlur, effectView, blurMask, tintWash, fallbackGradient] {
            view.frame = bounds
        }
        updateGradients()
        if monitor.scrollView == nil { attachMonitor() }
        updateVisibility()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachMonitor()
        scrollViewCheck?.invalidate()
        scrollViewCheck = nil
        guard window != nil else { return }
        // SwiftUI can swap the scroll view underneath — another chat opened.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reattachIfScrollViewLeft() }
        }
        RunLoop.main.add(timer, forMode: .default)
        scrollViewCheck = timer
    }

    private func updateGradients() {
        let fadeLength = 1 - startOffset
        blurMask.update(edge: edge, color: .black,
                        stops: Self.rising(to: fadeLength * Self.blurRampShare) + [(1, 1)])
        let rising = Self.rising(to: fadeLength) + [(1, 1)]
        let washColor = wash.resolvedColor(with: traitCollection)
        tintWash.update(edge: edge, color: washColor.withAlphaComponent(Self.washOpacity), stops: rising)
        fallbackGradient.update(edge: edge, color: washColor, stops: rising.map { ($0.location, $0.alpha * strength) })
    }

    /// Eased from nothing at the far side to full at `end`.
    private static func rising(to end: CGFloat) -> [GradientStop] {
        (0...fadeSamples).map { sample in
            let t = CGFloat(sample) / CGFloat(fadeSamples)
            return (end * t, smoothstep(0, 1, t))
        }
    }

    private func updateVisibility() {
        let coverage = contentCoverage()
        let blurAlpha = liveBlurAmount * coverage
        if blurContainer.alpha != blurAlpha { blurContainer.alpha = blurAlpha }
        let blurHidden = blurAlpha == 0 || strength == 0
        if blurContainer.isHidden != blurHidden { blurContainer.isHidden = blurHidden }
        let fallbackAlpha = (1 - liveBlurAmount) * coverage
        if fallbackGradient.alpha != fallbackAlpha { fallbackGradient.alpha = fallbackAlpha }
        if fallbackGradient.isHidden != (fallbackAlpha == 0) { fallbackGradient.isHidden = fallbackAlpha == 0 }
    }

    /// How much content is hidden past this edge, eased over a few points:
    /// nothing under it, nothing drawn.
    private func contentCoverage() -> CGFloat {
        guard let scrollView = monitor.scrollView else { return 1 }
        let inset = scrollView.adjustedContentInset
        let offset = scrollView.contentOffset
        let hidden: CGFloat = switch edge {
        case .top: offset.y + inset.top
        case .bottom: scrollView.contentSize.height + inset.bottom - (offset.y + scrollView.bounds.height)
        }
        return smoothstep(0, Self.coverageFadeDistance, hidden)
    }

    private func attachMonitor() {
        guard window != nil else {
            monitor.stop()
            return
        }
        monitor.observe(findScrollViewBehind())
        updateVisibility()
    }

    private func reattachIfScrollViewLeft() {
        guard let scrollView = monitor.scrollView, scrollView.window == nil else { return }
        monitor.stop()
        attachMonitor()
    }

    /// The scroll view drawn under this one: an earlier sibling, at any
    /// level up, that overlaps it on screen.
    private func findScrollViewBehind() -> UIScrollView? {
        let frame = convert(bounds, to: nil)
        var child: UIView = self
        while let container = child.superview {
            let index = container.subviews.firstIndex(of: child) ?? 0
            for sibling in container.subviews[..<index].reversed() {
                if let found = Self.scrollView(in: sibling, overlapping: frame) { return found }
            }
            child = container
        }
        return nil
    }

    private static func scrollView(in view: UIView, overlapping frame: CGRect) -> UIScrollView? {
        guard !view.isHidden, view.convert(view.bounds, to: nil).intersects(frame) else { return nil }
        // A text view is a scroll view too; the one wanted scrolls vertically.
        if let scroll = view as? UIScrollView, !(view is UITextView), scroll.isScrollEnabled { return scroll }
        for subview in view.subviews.reversed() {
            if let found = scrollView(in: subview, overlapping: frame) { return found }
        }
        return nil
    }
}

private typealias GradientStop = (location: CGFloat, alpha: CGFloat)

/// A system blur held part-way: an animator towards the material, paused at
/// `intensity`. Re-applied when the app comes back, because iOS finishes
/// paused animators on the way to the background.
@MainActor
private final class PartialBlurView: UIVisualEffectView {
    var intensity: CGFloat = 0.5 {
        didSet {
            intensity = max(0.01, min(1, intensity))
            if intensity != oldValue { apply() }
        }
    }

    private var animator: UIViewPropertyAnimator?
    private var observer: NSObjectProtocol?

    init() {
        super.init(effect: nil)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            animator?.stopAnimation(true)
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        guard window != nil else { return }
        animator?.stopAnimation(true)
        effect = nil
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [unowned self] in
            self.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = intensity
        self.animator = animator
    }
}

@MainActor
private final class EdgeGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    /// Strongest at `edge`, fading to nothing at the opposite side.
    func update(edge: ProgressiveBlur.Edge, color: UIColor, stops: [GradientStop]) {
        let base = color.cgColor.alpha
        gradient.colors = stops.map { color.withAlphaComponent(base * $0.alpha).cgColor }
        gradient.locations = stops.map { NSNumber(value: Double($0.location)) }
        switch edge {
        case .top:
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        case .bottom:
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
    }
}

/// Follows the scroll view behind: where it is, and how fast it moves. Fast
/// flings fade the blur out for a gradient, slow ones bring it back.
@MainActor
private final class ScrollSpeedMonitor: NSObject {
    private static let slowSpeed: CGFloat = 500
    private static let fastSpeed: CGFloat = 1500
    private static let smoothing: CGFloat = 0.1
    private static let fadeOut: CGFloat = 0.08
    private static let fadeIn: CGFloat = 0.2

    private(set) weak var scrollView: UIScrollView?
    private(set) var blurAmount: CGFloat = 1
    var onChange: (() -> Void)?
    var onBlurAmount: ((CGFloat) -> Void)?

    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var link: CADisplayLink?
    private var lastOffset = CGPoint.zero
    private var lastTimestamp: CFTimeInterval = 0
    private var speed: CGFloat = 0

    func observe(_ scrollView: UIScrollView?) {
        guard scrollView !== self.scrollView else { return }
        stop()
        self.scrollView = scrollView
        offsetObservation = scrollView?.observe(\.contentOffset, options: [.old]) { [weak self] _, change in
            MainActor.assumeIsolated {
                self?.onChange?()
                self?.scrolled(from: change.oldValue)
            }
        }
        sizeObservation = scrollView?.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func stop() {
        offsetObservation?.invalidate()
        offsetObservation = nil
        sizeObservation?.invalidate()
        sizeObservation = nil
        scrollView = nil
        link?.invalidate()
        link = nil
        speed = 0
        setBlurAmount(1)
    }

    private func scrolled(from old: CGPoint?) {
        guard link == nil, let scrollView else { return }
        lastOffset = old ?? scrollView.contentOffset
        lastTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else {
            stop()
            return
        }
        let elapsed = CGFloat(max(link.timestamp - lastTimestamp, 1.0 / 240))
        let offset = scrollView.contentOffset
        let instant = hypot(offset.x - lastOffset.x, offset.y - lastOffset.y) / elapsed
        lastOffset = offset
        lastTimestamp = link.timestamp
        speed += (instant - speed) * min(1, elapsed / Self.smoothing)
        let target = 1 - smoothstep(Self.slowSpeed, Self.fastSpeed, speed)
        let duration = target < blurAmount ? Self.fadeOut : Self.fadeIn
        var next = blurAmount + (target - blurAmount) * min(1, elapsed / duration)
        if abs(target - next) < 0.01 { next = target }
        setBlurAmount(next)
        if speed < 5, blurAmount == 1 {
            speed = 0
            self.link?.invalidate()
            self.link = nil
        }
    }

    private func setBlurAmount(_ amount: CGFloat) {
        guard amount != blurAmount else { return }
        blurAmount = amount
        onBlurAmount?(amount)
    }
}

private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}
