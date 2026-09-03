import SwiftUI

/// A bot's mark: a colour and a shape, and nothing else.
///
/// Hermes has no field for this — a profile is a name, a SOUL and a model —
/// so it is kept on the phone. That is the right place for it: losing it
/// costs a colour, not a bot, and the agent has no use for one.
struct BotMark: Codable, Hashable, Sendable {
    var colour: Int
    var shape: Int

    static let colours: [Color] = [
        Color(hex: 0xF5F3EE), Color(hex: 0x9C6B4A), Color(hex: 0xE5484D),
        Color(hex: 0xE8722B), Color(hex: 0xE5A93B), Color(hex: 0x5BBE7C),
        Color(hex: 0x4FB5A5), Color(hex: 0x3B82F6), Color(hex: 0x8B5CF6),
        Color(hex: 0xEC4899), Color(hex: 0x8A8A8E),
    ]

    /// Eight silhouettes, distinct enough to tell apart at 28pt in a list.
    enum Silhouette: Int, CaseIterable {
        case circle, squircle, square, capsule, triangle, hexagon, cloud, drop
    }

    var color: Color { Self.colours[colour % Self.colours.count] }
    var silhouette: Silhouette {
        Silhouette(rawValue: shape % Silhouette.allCases.count) ?? .circle
    }

    /// A stable mark for a bot nobody has chosen one for, so a fresh install
    /// shows a list of distinguishable things rather than a column of
    /// identical grey circles.
    /// Deterministic on purpose. `hashValue` is seeded per process, so a bot
    /// would change colour every launch — and two of three collided on the
    /// first run anyway.
    static func derived(from name: String) -> BotMark {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        // From index 1: the first colour is near-white, which is a fine thing
        // to choose on purpose and an invisible thing to be given, since the
        // card behind it is near-white too.
        return BotMark(
            colour: 1 + Int(hash % UInt64(colours.count - 1)),
            shape: Silhouette.circle.rawValue
        )
    }
}

/// The expressive face drawn inside a bot mark.
struct BotFaceView: View {
    let size: CGFloat
    var animated: Bool = false

    @State private var blinkScaleY: CGFloat = 1.0
    @State private var rightEyeBlinkScaleY: CGFloat = 1.0
    @State private var lookOffset: CGSize = .zero
    @State private var eyeAngle: Double = 12
    @State private var eyeScaleX: CGFloat = 1.0
    @State private var isWinking = false

    var body: some View {
        let eyeWidth = max(1.5, size * 0.125)
        let eyeHeight = max(4.0, size * 0.34)
        let spacing = max(1.2, size * 0.09)

        HStack(spacing: spacing) {
            Capsule()
                .fill(Color.black.opacity(0.88))
                .frame(width: eyeWidth, height: eyeHeight)
                .scaleEffect(x: eyeScaleX, y: blinkScaleY, anchor: .center)
            Capsule()
                .fill(Color.black.opacity(0.88))
                .frame(width: eyeWidth, height: eyeHeight)
                .scaleEffect(
                    x: eyeScaleX,
                    y: isWinking ? 0.08 : (animated ? rightEyeBlinkScaleY : blinkScaleY),
                    anchor: .center
                )
        }
        .rotationEffect(.degrees(eyeAngle))
        .offset(
            x: size * 0.05 + (animated ? lookOffset.width : 0),
            y: size * 0.03 + (animated ? lookOffset.height : 0)
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: lookOffset)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: eyeAngle)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: eyeScaleX)
        .task {
            guard animated else { return }
            while !Task.isCancelled {
                // Livelier, more frequent actions (1.4 to 2.8s)
                let waitSec = Double.random(in: 1.4...2.8)
                try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                if Task.isCancelled { break }

                let roll = Int.random(in: 0...10)
                if roll <= 4 {
                    // Natural snappy blink
                    withAnimation(.easeOut(duration: 0.08)) {
                        blinkScaleY = 0.06
                        rightEyeBlinkScaleY = 0.06
                    }
                    try? await Task.sleep(nanoseconds: 85_000_000)
                    withAnimation(.easeIn(duration: 0.1)) {
                        blinkScaleY = 1.0
                        rightEyeBlinkScaleY = 1.0
                    }
                    // 35% chance of lively double-blink
                    if Bool.random() {
                        try? await Task.sleep(nanoseconds: 110_000_000)
                        withAnimation(.easeOut(duration: 0.07)) {
                            blinkScaleY = 0.06
                            rightEyeBlinkScaleY = 0.06
                            eyeScaleX = 1.2
                        }
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        withAnimation(.easeIn(duration: 0.1)) {
                            blinkScaleY = 1.0
                            rightEyeBlinkScaleY = 1.0
                            eyeScaleX = 1.0
                        }
                    }
                } else if roll <= 8 {
                    // Pronounced, wide glances across the screen
                    let glances: [(offset: CGSize, angle: Double)] = [
                        (CGSize(width: -size * 0.11, height: -size * 0.02), 2.0),
                        (CGSize(width: size * 0.12, height: -size * 0.02), 22.0),
                        (CGSize(width: 0, height: -size * 0.09), 12.0),
                        (CGSize(width: size * 0.09, height: -size * 0.07), 24.0),
                        (CGSize(width: -size * 0.09, height: size * 0.04), 0.0),
                        (CGSize(width: size * 0.05, height: size * 0.06), 16.0),
                    ]
                    let target = glances.randomElement()!
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                        lookOffset = target.offset
                        eyeAngle = target.angle
                    }
                    let holdTime = Double.random(in: 1.1...2.2)
                    try? await Task.sleep(nanoseconds: UInt64(holdTime * 1_000_000_000))
                    if Task.isCancelled { break }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        lookOffset = .zero
                        eyeAngle = 12
                    }
                } else {
                    // Playful, clear wink with angle tilt
                    withAnimation(.easeOut(duration: 0.12)) {
                        isWinking = true
                        eyeAngle = 20
                        lookOffset = CGSize(width: size * 0.04, height: -size * 0.03)
                    }
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    withAnimation(.easeIn(duration: 0.12)) {
                        isWinking = false
                        eyeAngle = 12
                        lookOffset = .zero
                    }
                }
            }
        }
    }
}

/// An animated hero mark view with pronounced floating, tilting and interactive responsiveness.
struct AnimatedBotMarkView: View {
    let mark: BotMark
    var size: CGFloat = 84

    @State private var floatOffset: CGFloat = 0
    @State private var floatScale: CGFloat = 1.0
    @State private var floatTilt: Double = 0
    @State private var bounceScale: CGFloat = 1.0
    @State private var bounceRotation: Double = 0

    var body: some View {
        ZStack {
            MarkShape(silhouette: mark.silhouette)
                .fill(mark.color)
                .overlay {
                    MarkShape(silhouette: mark.silhouette)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                }

            BotFaceView(size: size, animated: true)
        }
        .frame(width: size, height: size)
        .scaleEffect(floatScale * bounceScale)
        .rotationEffect(.degrees(floatTilt + bounceRotation))
        .offset(y: floatOffset)
        .contentShape(.rect)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) {
                bounceScale = 1.22
                bounceRotation = 10
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                    bounceRotation = -6
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    bounceScale = 1.0
                    bounceRotation = 0
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                floatOffset = -12
                floatScale = 1.06
                floatTilt = 3.5
            }
        }
    }
}

/// Draws a mark at any size.
struct BotMarkView: View {
    let mark: BotMark
    var size: CGFloat = 28
    var animated: Bool = false

    var body: some View {
        if animated {
            AnimatedBotMarkView(mark: mark, size: size)
        } else {
            ZStack {
                MarkShape(silhouette: mark.silhouette)
                    .fill(mark.color)
                    // A hairline, so the palest colour still reads on a light card
                    // and the darkest still reads on a dark one.
                    .overlay {
                        MarkShape(silhouette: mark.silhouette)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                    }

                BotFaceView(size: size, animated: false)
            }
            .frame(width: size, height: size)
        }
    }
}

private struct MarkShape: InsettableShape {
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> MarkShape {
        MarkShape(inset: inset + amount, silhouette: silhouette)
    }

    let silhouette: BotMark.Silhouette

    func path(in outer: CGRect) -> Path {
        let rect = outer.insetBy(dx: inset, dy: inset)
        switch silhouette {
        case .circle:
            return Circle().path(in: rect)
        case .squircle:
            return RoundedRectangle(cornerRadius: rect.width * 0.3, style: .continuous)
                .path(in: rect)
        case .square:
            return RoundedRectangle(cornerRadius: rect.width * 0.14, style: .continuous)
                .path(in: rect)
        case .capsule:
            return Capsule().path(in: rect.insetBy(dx: 0, dy: rect.height * 0.22))
        case .triangle:
            return polygon(sides: 3, in: rect, rotation: -.pi / 2)
        case .hexagon:
            return polygon(sides: 6, in: rect, rotation: -.pi / 2)
        case .cloud:
            var path = Path()
            let r = rect.width / 2
            path.addEllipse(in: CGRect(x: rect.minX, y: rect.midY - r * 0.55,
                                       width: r * 1.2, height: r * 1.2))
            path.addEllipse(in: CGRect(x: rect.maxX - r * 1.2, y: rect.midY - r * 0.55,
                                       width: r * 1.2, height: r * 1.2))
            path.addEllipse(in: CGRect(x: rect.midX - r * 0.7, y: rect.minY,
                                       width: r * 1.4, height: r * 1.4))
            path.addRect(CGRect(x: rect.minX + r * 0.3, y: rect.midY,
                                width: rect.width - r * 0.6, height: r * 0.75))
            return path
        case .drop:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.maxY),
                control: CGPoint(x: rect.maxX + rect.width * 0.12, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.minY),
                control: CGPoint(x: rect.minX - rect.width * 0.12, y: rect.maxY)
            )
            return path
        }
    }

    private func polygon(sides: Int, in rect: CGRect, rotation: CGFloat) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for step in 0..<sides {
            let angle = rotation + CGFloat(step) * 2 * .pi / CGFloat(sides)
            let point = CGPoint(
                x: centre.x + radius * cos(angle),
                y: centre.y + radius * sin(angle)
            )
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
