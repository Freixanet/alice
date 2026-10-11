import SwiftUI

/// iOS 27 fails to render soft beneath custom bottom bars. Retain the native
/// top edge and use a fixed public-material fallback only for that bottom edge.
struct ProgressiveScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollEdgeEffectHidden(ProgressiveBottomScrollEdge.usesFallback, for: .bottom)
    }
}
