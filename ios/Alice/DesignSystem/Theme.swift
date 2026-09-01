import SwiftUI

/// The palette Alice uses on the web, ported so the two clients read as one
/// product: warm paper in light, near-black in dark, and an accent the user
/// picks that tints selection rather than shouting.
enum Accent: String, CaseIterable, Identifiable, Sendable {
    case stone, sage, sky, violet, rose, amber

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .stone: "Stone"
        case .sage: "Sage"
        case .sky: "Sky"
        case .violet: "Violet"
        case .rose: "Rose"
        case .amber: "Amber"
        }
    }

    /// The swatch shown in Settings, identical in both themes.
    var swatch: Color {
        switch self {
        case .stone: Color(hex: 0xD4D0C8)
        case .sage: Color(hex: 0x8FA894)
        case .sky: Color(hex: 0x7FA3BF)
        case .violet: Color(hex: 0xA392BE)
        case .rose: Color(hex: 0xC49293)
        case .amber: Color(hex: 0xC4A574)
        }
    }

    func primary(_ scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.stone, .dark): Color(hex: 0xECECEA)
        case (.stone, _): Color(hex: 0x1A1A18)
        case (.sage, .dark): Color(hex: 0x9AAF9C)
        case (.sage, _): Color(hex: 0x4F6D55)
        case (.sky, .dark): Color(hex: 0x7FA3BF)
        case (.sky, _): Color(hex: 0x3D6580)
        case (.violet, .dark): Color(hex: 0xA392BE)
        case (.violet, _): Color(hex: 0x65548A)
        case (.rose, .dark): Color(hex: 0xC49293)
        case (.rose, _): Color(hex: 0x8F5456)
        case (.amber, .dark): Color(hex: 0xC4A574)
        case (.amber, _): Color(hex: 0x8A6A38)
        }
    }
}

enum ThemeChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Surface colours. Liquid Glass supplies its own material, so these are for
/// the page behind it and for the few solid surfaces that sit on top.
enum Palette {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0B0B0C) : Color(hex: 0xF4F3EF)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x151517) : Color(hex: 0xFFFCF7)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xEBE9E2)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.16)
            : Color(hex: 0x1A1A18).opacity(0.18)
    }
}

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

extension Font {
    /// Titles are a serif on the web. Rather than bundle a face, this uses the
    /// system serif, which carries the same weight of voice and stays legible
    /// at every Dynamic Type size.
    static func aliceTitle(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .serif)
    }
}
