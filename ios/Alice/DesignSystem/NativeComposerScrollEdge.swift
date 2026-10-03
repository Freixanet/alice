import SwiftUI
import UIKit

/// Explicit public UIKit relationship between this transcript and its composer.
/// No blur view, tint layer, timers or per-message calculations are involved.
@MainActor
final class ComposerScrollEdgeLink {
    private weak var scrollView: UIScrollView?
    private weak var container: UIView?
    private let interaction = UIScrollEdgeElementContainerInteraction()
    private var reportedConnection = false
    private var reportedLayout = false
    private var diagnosisScheduled = false
    private var originalDiagnosticOffset: CGPoint?
    private var fixedDiagnosticOffset: CGPoint?

    func attachScrollView(_ scrollView: UIScrollView) {
        if self.scrollView !== scrollView { reportedConnection = false; reportedLayout = false }
        self.scrollView = scrollView
        connect()
    }

    func attachContainer(_ container: UIView) {
        if self.container !== container {
            self.container?.removeInteraction(interaction)
            self.container = container
            container.addInteraction(interaction)
        }
        connect()
    }

    func detachContainer(_ container: UIView) {
        guard self.container === container else { return }
        container.removeInteraction(interaction)
        self.container = nil
        interaction.scrollView = nil
    }

    func reportLayout() {
        guard !reportedLayout, let scrollView, let container,
              let window = container.window, scrollView.window === window,
              scrollView.bounds.height > 0, container.bounds.height > 0 else { return }
        reportedLayout = true
        let viewport = scrollView.convert(scrollView.bounds, to: window)
        let controls = container.convert(container.bounds, to: window)
        DiagnosticsLog.write("chat.bottomEdge.geometry scrollBottom=\(Int(viewport.maxY)) composerTop=\(Int(controls.minY)) composerBottom=\(Int(controls.maxY)) bottomInset=\(Int(scrollView.adjustedContentInset.bottom))")
    }

    private func scheduleDiagnosisIfRequested() {
        #if DEBUG
        guard !diagnosisScheduled,
              ProcessInfo.processInfo.arguments.contains("--alice-edge-diagnose") else { return }
        diagnosisScheduled = true
        for delay in [1.0, 3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.recordDiagnosis(delay: delay)
            }
        }
        #endif
    }

    #if DEBUG
    private func recordDiagnosis(delay: Double) {
        guard let scrollView, let container, let window = container.window,
              scrollView.window === window else {
            DiagnosticsLog.write("chat.edgeDiagnostic missingWindow delay=\(delay)")
            return
        }
        if delay == 1 {
            originalDiagnosticOffset = scrollView.contentOffset
            fixedDiagnosticOffset = CGPoint(x: scrollView.contentOffset.x,
                y: max(-scrollView.adjustedContentInset.top,
                       scrollView.contentSize.height - scrollView.bounds.height - 160))
        }
        if let offset = fixedDiagnosticOffset {
            scrollView.setContentOffset(offset, animated: false)
            window.layoutIfNeeded()
        }
        DiagnosticsLog.write("chat.edgeDiagnostic state delay=\(delay) bottomHidden=\(scrollView.bottomEdgeEffect.isHidden) bottomSoft=\(scrollView.bottomEdgeEffect.style == .soft) topHidden=\(scrollView.topEdgeEffect.isHidden) topSoft=\(scrollView.topEdgeEffect.style == .soft) attached=\(interaction.scrollView === scrollView) installed=\(container.interactions.contains { $0 === interaction }) reduceTransparency=\(UIAccessibility.isReduceTransparencyEnabled)")
        let frame = scrollView.convert(scrollView.bounds, to: window)
        DiagnosticsLog.write("chat.edgeDiagnostic scroll rect=\(frame) offset=\(scrollView.contentOffset) contentSize=\(scrollView.contentSize) inset=\(scrollView.adjustedContentInset) safe=\(scrollView.safeAreaInsets) clipped=\(scrollView.clipsToBounds)")
        guard delay == 3 || delay == 6 || delay == 10 else { return }
        func describe(_ view: UIView, depth: Int) {
            guard depth < 12 else { return }
            let rect = view.convert(view.bounds, to: window)
            DiagnosticsLog.write("chat.edgeDiagnostic node depth=\(depth) type=\(String(describing: type(of: view))) rect=\(rect) hidden=\(view.isHidden) alpha=\(view.alpha) clipped=\(view.clipsToBounds) mask=\(view.layer.mask != nil) control=\(view is UIControl) image=\(view is UIImageView) label=\(view is UILabel) visualEffect=\(view is UIVisualEffectView)")
            for child in view.subviews { describe(child, depth: depth + 1) }
        }
        describe(container, depth: 0)
        var ancestor: UIView? = scrollView.superview
        while let view = ancestor {
            DiagnosticsLog.write("chat.edgeDiagnostic ancestor type=\(String(describing: type(of: view))) rect=\(view.convert(view.bounds, to: window)) clipped=\(view.clipsToBounds) mask=\(view.layer.mask != nil)")
            ancestor = view.superview
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let cgImage = image.cgImage else { return }
        for (name, rect) in [
            ("top", CGRect(x: 0, y: 0, width: window.bounds.width, height: 230)),
            ("bottom", CGRect(x: 0, y: max(0, window.bounds.height - 300), width: window.bounds.width, height: 300))
        ] {
            let pixels = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                                width: rect.width * image.scale, height: rect.height * image.scale)
            if let cropped = cgImage.cropping(to: pixels), let data = UIImage(cgImage: cropped).pngData() {
                try? data.write(to: directory.appendingPathComponent("edge-diagnostic-\(name)-\(Int(delay)).png"))
            }
        }
        DiagnosticsLog.write("chat.edgeDiagnostic snapshots saved")
        if delay == 10, let offset = originalDiagnosticOffset {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak scrollView] in
                scrollView?.setContentOffset(offset, animated: false)
            }
        }
    }
    #endif

    private func connect() {
        guard let scrollView, container != nil else { return }
        interaction.edge = .bottom
        interaction.scrollView = scrollView
        scrollView.bottomEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.isHidden = false
        scheduleDiagnosisIfRequested()
        if !reportedConnection {
            reportedConnection = true
            DiagnosticsLog.write("chat.bottomEdge.attached style=soft hidden=false")
        }
    }
}

/// Placed INSIDE the transcript content, so the first public UIScrollView
/// ancestor is this transcript, never a text editor or another chat's scroll.
struct TranscriptScrollEdgeAnchor: UIViewRepresentable {
    let link: ComposerScrollEdgeLink

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.link = link
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) { view.link = link }

    final class Anchor: UIView {
        weak var link: ComposerScrollEdgeLink?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    link?.attachScrollView(scroll)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// Own a concrete container for the existing SwiftUI composer, as required by
/// UIScrollEdgeElementContainerInteraction. Its content and controls are unchanged.
struct NativeComposerScrollEdge<ComposerContent: View>: UIViewControllerRepresentable {
    let link: ComposerScrollEdgeLink
    let composer: ComposerContent

    func makeUIViewController(context: Context) -> ComposerEdgeHostingController<ComposerContent> {
        let controller = ComposerEdgeHostingController(rootView: composer)
        controller.edgeLink = link
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        controller.sizingOptions = .intrinsicContentSize
        link.attachContainer(controller.view)
        return controller
    }

    func updateUIViewController(_ controller: ComposerEdgeHostingController<ComposerContent>, context: Context) {
        controller.rootView = composer
        link.attachContainer(controller.view)
        controller.view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: ComposerEdgeHostingController<ComposerContent>,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func makeCoordinator() -> ComposerScrollEdgeLink { link }

    static func dismantleUIViewController(
        _ controller: ComposerEdgeHostingController<ComposerContent>, coordinator: ComposerScrollEdgeLink
    ) {
        coordinator.detachContainer(controller.view)
    }
}

@MainActor
final class ComposerEdgeHostingController<Content: View>: UIHostingController<Content> {
    weak var edgeLink: ComposerScrollEdgeLink?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        edgeLink?.reportLayout()
    }
}
