import SwiftUI

// The app's answers to a finger landing on something, in one place (`Haptic` is the other half).

/// Something that answers the finger the instant it lands, as the system's
/// own controls do: a small give on touch-down (ease-out, a tenth of a
/// second), a critically damped spring back on release. Under Reduce Motion
/// the give becomes a dim, with no movement.
struct PressableCardStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale)
    }

    private struct PressBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        let scale: CGFloat

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .scaleEffect(pressed && !reduceMotion ? scale : 1)
                .opacity(pressed ? (reduceMotion ? 0.6 : 0.85) : 1)
                .animation(
                    pressed ? .easeOut(duration: 0.1) : .spring(response: 0.3, dampingFraction: 1),
                    value: pressed
                )
        }
    }
}

/// The same answer for a small control — a row, a chip, an icon: dims and
/// gives a touch more, since there is less of it to see move.
extension ButtonStyle where Self == PressableCardStyle {
    static var pressable: PressableCardStyle { PressableCardStyle(scale: 0.95) }
}

/// A row that answers the finger as a list row does: a faint wash on touch-down, gone on
/// release. No movement, so it reads the same with Reduce Motion on or off.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0))
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableRowStyle {
    static var pressableRow: PressableRowStyle { PressableRowStyle() }
}
