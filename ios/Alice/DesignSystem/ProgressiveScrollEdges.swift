import SwiftUI

/// The header uses iOS 26's native edge. The composer supplies an explicit
/// material band because its native bottom edge is not visible in this layout.
struct ProgressiveScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
    }
}

/// Fixed viewport transition immediately above the composer, continuing into
/// the page colour beneath its controls. No message measurements or scroll work.
struct ComposerScrollEdge: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let transitionHeight: CGFloat = 64

    private var blurRamp: LinearGradient {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .white.opacity(0.08), location: 0.12),
            .init(color: .white.opacity(0.28), location: 0.28),
            .init(color: .white.opacity(0.58), location: 0.46),
            .init(color: .white.opacity(0.85), location: 0.72),
            .init(color: .white, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private var fadeRamp: LinearGradient {
        let background = Palette.background(scheme)
        return LinearGradient(stops: [
            .init(color: background.opacity(0), location: 0),
            .init(color: background.opacity(0.01), location: 0.12),
            .init(color: background.opacity(0.06), location: 0.28),
            .init(color: background.opacity(0.2), location: 0.46),
            .init(color: background.opacity(0.5), location: 0.72),
            .init(color: background, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if !reduceTransparency {
                    Rectangle()
                        .fill(.regularMaterial)
                        .mask(blurRamp)
                }
                fadeRamp
            }
            .frame(height: Self.transitionHeight)
            Palette.background(scheme)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
