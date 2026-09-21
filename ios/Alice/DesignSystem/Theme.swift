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

    /// The chosen accent, resolved for a scheme.
    ///
    /// Read this rather than `Color.accentColor`, which resolves the asset
    /// catalogue's colour and ignores the environment's `.tint` entirely — the
    /// accent setting appeared to do nothing because every place that showed
    /// it was drawing the system blue instead.
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

    /// The fill for a control with a white knob on it — a switch, chiefly.
    ///
    /// `primary` is tuned for text and glyphs, where the contrast that matters
    /// is against the background. A switch inverts that: iOS draws the knob
    /// white, so the *track* is the background and it has to stay dark enough
    /// for the knob to read against it. Stone's dark primary is 0xECECEA,
    /// which put a white knob on a near-white track and made the switch look
    /// broken rather than on. Only that one is moved; every other accent
    /// already sits mid-tone and is passed through unchanged.
    func control(_ scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.stone, .dark): Color(hex: 0x6C6C68)
        default: primary(scheme)
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

    /// What a link is set in, whatever the theme.
    ///
    /// Deliberately outside the accent. The accent is a preference, and one
    /// of them — Stone, the default — is #ECECEA in the dark, the same
    /// near-white the body is set in: links took it faithfully and became
    /// invisible. A link also has a colour people already know, and blue is
    /// the one word of that vocabulary everybody speaks.
    ///
    /// Not the system blue, which is louder than anything else on these
    /// screens. A step deeper in the light so it holds against off-white
    /// paper, a step lighter in the dark so it does not vibrate against
    /// near-black.
    static func link(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x7FA9F0) : Color(hex: 0x2C5FC4)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xEBE9E2)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.16)
            : Color(hex: 0x1A1A18).opacity(0.18)
    }

    // MARK: State

    /// Colours that say how something is going, and nothing else: a save
    /// that landed, a routine that failed, a message waiting its turn. Each
    /// is used only for state, never for decoration, and each is a step
    /// quieter than the system's so it sits with the paper rather than on it.
    /// Both readings meet AA against `background` and `card`.

    /// Done, delivered, healthy.
    static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x7CC49A) : Color(hex: 0x2E7D4F)
    }

    /// Waiting, retrying, needs a look but nothing is lost.
    static func warning(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xE0B25C) : Color(hex: 0x9A6B10)
    }

    /// Failed, refused, or about to delete.
    static func danger(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xE58C8C) : Color(hex: 0xB23A3A)
    }

    /// In progress, informational, neither a success nor a failure.
    static func info(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x8BB4D9) : Color(hex: 0x3D6580)
    }
}


extension Font {
    /// The same face the web sets its titles in, bundled rather than
    /// approximated: the system serif is close in spirit but visibly a
    /// different letter, and the two clients should look like one product.
    ///
    /// `.custom(size:relativeTo:)` keeps it scaling with Dynamic Type.
    static func aliceTitle(_ style: Font.TextStyle = .largeTitle) -> Font {
        .custom("InstrumentSerif-Regular", size: baseSize(style), relativeTo: style)
    }

    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 40
        case .title: 32
        case .title2: 25
        case .title3: 22
        case .headline, .body: 18
        default: 16
        }
    }
}

extension View {
    /// The paper behind a Form, including the band a grouped list otherwise
    /// leaves system-white below the last section.
    func aliceFormPaper(_ scheme: ColorScheme) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { Palette.background(scheme).ignoresSafeArea() }
            .containerBackground(Palette.background(scheme), for: .navigation)
    }
}
