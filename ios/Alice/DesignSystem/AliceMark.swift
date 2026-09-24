import SwiftUI

/// The conversation's face at the top of a chat: a round portrait with
/// the name on glass overlapping the chin.
struct ChatHeaderAvatar<Face: View>: View {
    var size: CGFloat = 72
    let name: String
    var face: Face
    /// When set, the face is where a zoom transition starts: the page it
    /// opens grows out of this disc and shrinks back into it.
    var zoomSource: (id: String, namespace: Namespace.ID)?

    init(size: CGFloat = 72, name: String, zoomSource: (id: String, namespace: Namespace.ID)? = nil,
         @ViewBuilder face: () -> Face) {
        self.size = size
        self.name = name
        self.zoomSource = zoomSource
        self.face = face()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The agent portraits are painted on this same near-white
                // disc. Alice's asset is cut out, so without it her edge
                // falls into the paper and the two kinds of face do not match.
                Circle().fill(Color(hex: 0xFDFDFD))
                face
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .modifier(ZoomSource(source: zoomSource))

            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .offset(y: -10)
        }
        .padding(.bottom, -2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

/// Alice's face in her own chat, with her name on the glass under it.
struct AliceAvatar: View {
    var size: CGFloat = 72
    /// The god portraits paint a white ring of about 16px on a 384px
    /// square. Alice's cutout fills the disc, so the same fraction is
    /// inset here and the disc behind her shows through.
    private static let halo: CGFloat = 16.0 / 384.0

    var body: some View {
        ChatHeaderAvatar(size: size, name: "Alice") {
            Image("AliceAvatar")
                .resizable()
                .renderingMode(.original)
                .scaledToFill()
                .padding(size * Self.halo)
        }
    }
}

/// The mark from the web client, drawn rather than shipped as an image so it
/// takes the current foreground colour and any size without a second asset to
/// keep in step.
///
/// One canvas, not a stack of shapes: a `Path` laid out in a `ZStack` is
/// positioned by its own bounding box, so the wings and the flags each get
/// re-centred and the drawing falls apart. Here every stroke keeps the SVG's
/// 32-unit coordinates and the whole thing is scaled once.
struct AliceMark: View {
    var size: CGFloat = 24

    private static let box: CGFloat = 32

    var body: some View {
        Canvas { context, area in
            context.scaleBy(
                x: area.width / Self.box, y: area.height / Self.box
            )

            context.fill(flag(tip: 15.1, corner: 7.6, base: 9.4), with: .foreground)
            context.fill(flag(tip: 16.9, corner: 24.4, base: 22.6), with: .foreground)

            for direction in [-5.5, 5.5] as [CGFloat] {
                context.stroke(
                    wing(toward: direction),
                    with: .foreground,
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
            }

            context.fill(
                Path(roundedRect: CGRect(x: 15, y: 7.2, width: 2, height: 18.4),
                     cornerRadius: 1),
                with: .foreground
            )
        }
        .frame(width: size, height: size)
    }

    private func flag(tip: CGFloat, corner: CGFloat, base: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: tip, y: 7.4))
            path.addLine(to: CGPoint(x: corner, y: 5.1))
            path.addLine(to: CGPoint(x: base, y: 10.8))
            path.closeSubpath()
        }
    }

    private func wing(toward dx: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 16, y: 11.2))
            path.addCurve(
                to: CGPoint(x: 16, y: 21.2),
                control1: CGPoint(x: 16 + dx, y: 12.7),
                control2: CGPoint(x: 16 + dx, y: 19.7)
            )
        }
    }
}


/// The disc a zoom transition grows from, clipped to its circle so the page
/// leaves and returns as the face itself rather than as a square around it.
private struct ZoomSource: ViewModifier {
    let source: (id: String, namespace: Namespace.ID)?

    func body(content: Content) -> some View {
        if let source {
            content.matchedTransitionSource(id: source.id, in: source.namespace) { config in
                config.clipShape(RoundedRectangle(cornerRadius: 36)).background(Color(hex: 0xFDFDFD))
            }
        } else {
            content
        }
    }
}
