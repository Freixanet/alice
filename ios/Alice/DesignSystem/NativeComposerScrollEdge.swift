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

    func attachScrollView(_ scrollView: UIScrollView) {
        if self.scrollView !== scrollView { reportedConnection = false }
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

    private func connect() {
        guard let scrollView, container != nil else { return }
        interaction.edge = .bottom
        interaction.scrollView = scrollView
        scrollView.bottomEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.isHidden = false
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

    func makeUIViewController(context: Context) -> UIHostingController<ComposerContent> {
        let controller = UIHostingController(rootView: composer)
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        controller.sizingOptions = .intrinsicContentSize
        link.attachContainer(controller.view)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<ComposerContent>, context: Context) {
        controller.rootView = composer
        link.attachContainer(controller.view)
        controller.view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: UIHostingController<ComposerContent>,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func makeCoordinator() -> ComposerScrollEdgeLink { link }

    static func dismantleUIViewController(
        _ controller: UIHostingController<ComposerContent>, coordinator: ComposerScrollEdgeLink
    ) {
        coordinator.detachContainer(controller.view)
    }
}
