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
            shape: Int((hash / 11) % UInt64(Silhouette.allCases.count))
        )
    }
}

/// Draws a mark at any size.
struct BotMarkView: View {
    let mark: BotMark
    var size: CGFloat = 28

    var body: some View {
        MarkShape(silhouette: mark.silhouette)
            .fill(mark.color)
            // A hairline, so the palest colour still reads on a light card
            // and the darkest still reads on a dark one.
            .overlay {
                MarkShape(silhouette: mark.silhouette)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
            }
            .frame(width: size, height: size)
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
