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

/// What the face is doing between events.
enum BotMood {
    /// Idling: the occasional blink, the occasional look around.
    case idle
    /// Working on a reply: a slower, steadier scan and longer blinks.
    case thinking
}

/// The face drawn inside a bot mark.
///
/// Eyes are believable when they move the way eyes move, which is not
/// smoothly. A real gaze shift is a saccade: 40–80ms of near-instant travel,
/// then a long hold. Easing one over a third of a second reads as a floating
/// object, not a look. So the movement here is fast and the stillness after it
/// is long, and a gaze change carries a blink with it — which is what people
/// actually do, and what makes the two read as one gesture rather than two
/// animations that happen to overlap.
struct BotFaceView: View {
    let size: CGFloat
    var animated: Bool = false
    var mood: BotMood = .idle
    /// The eyes' colour. Black on a bot's own coloured mark, where it always
    /// reads; but on a glass disc that follows the system theme it has to
    /// follow too, or in the dark it is ink on ink.
    var ink: Color = Color.black.opacity(0.88)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var leftLid: CGFloat = 1
    @State private var rightLid: CGFloat = 1
    @State private var gaze: CGSize = .zero
    @State private var tilt: Double = Self.restingTilt
    @State private var stretch: CGFloat = 1
    @State private var drift: CGSize = .zero

    /// The eyes sit slightly canted at rest; upright reads as a stare.
    private static let restingTilt: Double = 12

    private var moving: Bool { animated && !reduceMotion }

    var body: some View {
        let eyeWidth = max(1.5, size * 0.125)
        let eyeHeight = max(4.0, size * 0.34)
        let spacing = max(1.2, size * 0.09)

        HStack(spacing: spacing) {
            eye(width: eyeWidth, height: eyeHeight, lid: leftLid)
            eye(width: eyeWidth, height: eyeHeight, lid: rightLid)
        }
        .rotationEffect(.degrees(tilt))
        .offset(
            x: size * 0.05 + gaze.width + drift.width,
            y: size * 0.03 + gaze.height + drift.height
        )
        .task(id: mood) { await live() }
    }

    private func eye(width: CGFloat, height: CGFloat, lid: CGFloat) -> some View {
        Capsule()
            .fill(ink)
            .frame(width: width, height: height)
            .scaleEffect(x: stretch, y: lid, anchor: .center)
    }

    // MARK: - Behaviour

    private func live() async {
        guard moving else {
            // Reduce Motion: still a face, just a still one.
            leftLid = 1; rightLid = 1; gaze = .zero
            tilt = Self.restingTilt; stretch = 1; drift = .zero
            return
        }
        startDrift()
        while !Task.isCancelled {
            switch mood {
            case .idle: await idleBeat()
            case .thinking: await thinkingBeat()
            }
        }
    }

    /// A slow wander of well under a point, so the face is never quite frozen
    /// between events without ever looking restless.
    private func startDrift() {
        withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
            drift = CGSize(width: size * 0.006, height: -size * 0.008)
        }
    }

    private func idleBeat() async {
        // Longer than it was. Something happening every 1.4s reads as a
        // nervous tic; people blink roughly every four seconds.
        await pause(2.6...6.0)
        guard !Task.isCancelled else { return }

        // Weighted, not uniform. The old roll winked nearly a fifth of the
        // time, which is a lot of winking.
        switch Int.random(in: 0..<100) {
        case ..<55: await blink()
        case ..<90: await glance()
        case ..<97: await wink()
        default: await blink(twice: true)
        }
    }

    private func thinkingBeat() async {
        // Looking away and up is what somebody working something out does.
        let corners: [CGSize] = [
            CGSize(width: -size * 0.08, height: -size * 0.07),
            CGSize(width: size * 0.09, height: -size * 0.06),
        ]
        for corner in corners {
            guard !Task.isCancelled else { return }
            saccade(to: corner, tilt: corner.width < 0 ? 4 : 20)
            await pause(0.9...1.6)
            if Bool.random() { await blink(slow: true) }
        }
    }

    // MARK: - Gestures

    private func blink(twice: Bool = false, slow: Bool = false) async {
        let close = slow ? 0.13 : 0.075
        let open = slow ? 0.16 : 0.1
        withAnimation(.easeOut(duration: close)) { leftLid = 0.06; rightLid = 0.06 }
        try? await Task.sleep(for: .seconds(close + 0.02))
        withAnimation(.easeIn(duration: open)) { leftLid = 1; rightLid = 1 }
        guard twice, !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(0.11))
        withAnimation(.easeOut(duration: 0.07)) {
            leftLid = 0.06; rightLid = 0.06; stretch = 1.18
        }
        try? await Task.sleep(for: .seconds(0.08))
        withAnimation(.easeIn(duration: 0.1)) {
            leftLid = 1; rightLid = 1; stretch = 1
        }
    }

    private func glance() async {
        let targets: [(CGSize, Double)] = [
            (CGSize(width: -size * 0.11, height: -size * 0.02), 2),
            (CGSize(width: size * 0.12, height: -size * 0.02), 22),
            (CGSize(width: 0, height: -size * 0.09), 12),
            (CGSize(width: size * 0.09, height: -size * 0.07), 24),
            (CGSize(width: -size * 0.09, height: size * 0.04), 0),
            (CGSize(width: size * 0.05, height: size * 0.06), 16),
        ]
        guard let (offset, angle) = targets.randomElement() else { return }

        // The blink rides along with the shift rather than following it.
        withAnimation(.easeOut(duration: 0.06)) { leftLid = 0.2; rightLid = 0.2 }
        saccade(to: offset, tilt: angle)
        try? await Task.sleep(for: .seconds(0.08))
        withAnimation(.easeIn(duration: 0.09)) { leftLid = 1; rightLid = 1 }

        await pause(1.1...2.4)
        guard !Task.isCancelled else { return }
        saccade(to: .zero, tilt: Self.restingTilt)
    }

    private func wink() async {
        withAnimation(.easeOut(duration: 0.1)) {
            rightLid = 0.08
            tilt = 20
            gaze = CGSize(width: size * 0.04, height: -size * 0.03)
        }
        try? await Task.sleep(for: .seconds(0.28))
        withAnimation(.easeIn(duration: 0.12)) {
            rightLid = 1
            tilt = Self.restingTilt
            gaze = .zero
        }
    }

    /// Near-instant travel, the way a real gaze shift moves.
    private func saccade(to offset: CGSize, tilt angle: Double) {
        withAnimation(.easeOut(duration: 0.07)) {
            gaze = offset
            tilt = angle
        }
    }

    private func pause(_ range: ClosedRange<Double>) async {
        try? await Task.sleep(for: .seconds(Double.random(in: range)))
    }
}

/// A mark that answers a tap, and — where it has room — floats.
struct AnimatedBotMarkView: View {
    let mark: BotMark
    var size: CGFloat = 84
    var mood: BotMood = .idle
    /// The float is a flourish for a mark standing on its own. Beside a line
    /// of text it just lifts out of alignment with the name it belongs to.
    var floats: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var floating = false
    @State private var bounceScale: CGFloat = 1
    @State private var bounceRotation: Double = 0

    var body: some View {
        ZStack {
            MarkShape(silhouette: mark.silhouette)
                .fill(mark.color)
                .overlay {
                    MarkShape(silhouette: mark.silhouette)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                }

            BotFaceView(size: size, animated: true, mood: mood)
        }
        .frame(width: size, height: size)
        .scaleEffect((lifted ? 1.06 : 1) * bounceScale)
        .rotationEffect(.degrees((lifted ? 3.5 : 0) + bounceRotation))
        .offset(y: lifted ? -12 : 0)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 2).repeatForever(autoreverses: true),
            value: lifted
        )
        .contentShape(.rect)
        .onTapGesture { bounce() }
        // Driven by a value rather than started inside `onAppear`: a
        // repeatForever begun there stacks another copy every time the view
        // comes back, and does not always restart when it should.
        .onAppear { floating = true }
        .onDisappear { floating = false }
    }

    private var lifted: Bool { floats && floating }

    private func bounce() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard !reduceMotion else { return }
        Task { @MainActor in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) {
                bounceScale = 1.22
                bounceRotation = 10
            }
            try? await Task.sleep(for: .seconds(0.18))
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                bounceRotation = -6
            }
            try? await Task.sleep(for: .seconds(0.17))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                bounceScale = 1
                bounceRotation = 0
            }
        }
    }
}

/// Draws a mark at any size.
struct BotMarkView: View {
    let mark: BotMark
    var size: CGFloat = 28
    var animated: Bool = false
    var mood: BotMood = .idle
    var floats: Bool = true

    var body: some View {
        if animated {
            AnimatedBotMarkView(mark: mark, size: size, mood: mood, floats: floats)
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

                BotFaceView(size: size, animated: false, mood: mood)
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
