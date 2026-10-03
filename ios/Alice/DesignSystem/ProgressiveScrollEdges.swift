import SwiftUI

/// iOS 26 owns the progressive backdrop blur and background fade. The header
/// and composer use safeAreaBar so both effects extend beneath those controls.
/// Native rendering handles theme, accessibility and keyboard changes without
/// measuring messages, polling scroll offsets or adding a touch-blocking layer.
struct ProgressiveScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}
