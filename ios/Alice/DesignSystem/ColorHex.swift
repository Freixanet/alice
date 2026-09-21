import SwiftUI

// On its own so the Live Activity extension can draw a bot's mark with the same
// colours as the app, without taking the whole theme along.
extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A colour pulled toward black or white until small text clears WCAG AA
/// on the glass the chat header actually sits on.
enum LegibleColor {
    /// Light glass is near white; dark glass is a lifted charcoal, lighter
    /// than the page, which is the harder of the two for a pale ink.
    static func ink(_ hex: UInt32, on scheme: ColorScheme) -> UInt32 {
        let ground: UInt32 = scheme == .dark ? 0x3A3A3C : 0xFFFFFF
        let toward: UInt32 = scheme == .dark ? 0xFFFFFF : 0x141413
        if contrast(hex, ground) >= 4.5 { return hex }
        for step in 1...12 {
            let mixed = mix(hex, toward, Double(step) / 12)
            if contrast(mixed, ground) >= 4.5 { return mixed }
        }
        return toward
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let unit = Double(value) / 255
            return unit <= 0.04045 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
        }
        let red = channel((hex >> 16) & 0xFF)
        let green = channel((hex >> 8) & 0xFF)
        let blue = channel(hex & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let start = Double((from >> shift) & 0xFF)
            let end = Double((to >> shift) & 0xFF)
            return UInt32((start + (end - start) * amount).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}
