import SwiftUI

/// Both bars wrap the same chat surface. iOS supplies the matching native
/// blur/fade at each edge, including the safe area beneath the composer.
struct ProgressiveScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}
