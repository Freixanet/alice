import SwiftUI
import UIKit

/// Reading measure and leading for assistant prose.
///
/// Scaled from the current body point size so Dynamic Type keeps ~65–70
/// characters on a wide canvas and does not pin iPhone portrait, where the
/// screen is already narrower than that measure.
enum AliceReading {
    /// Extra space between lines so body leading lands near 1.32× point size.
    /// SwiftUI's `lineSpacing` is added on top of the font's built-in line height.
    static func extraLeading(for font: UIFont = .preferredFont(forTextStyle: .body)) -> CGFloat {
        max(0, font.pointSize * 1.32 - font.lineHeight)
    }

    /// Maximum width for prose. Code, tables and other wide blocks skip this.
    static func proseMeasure(for font: UIFont = .preferredFont(forTextStyle: .body)) -> CGFloat {
        font.pointSize * 34
    }

    /// Footnote-sized SF Mono with ligatures off so `!=`, `fi` and `=>` stay literal.
    static func monospacedCode(_ code: String) -> AttributedString {
        let size = UIFont.preferredFont(forTextStyle: .footnote).pointSize
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let ns = NSMutableAttributedString(string: code)
        let range = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.font, value: font, range: range)
        ns.addAttribute(.ligature, value: 0, range: range)
        return AttributedString(ns)
    }
}

/// Presentation-only punctuation for natural-language runs.
///
/// Never applied to the stored Hermes text. Inline code, links, and CLI-style
/// `--flags` are left untouched.
enum AliceTypography {
    static func present(_ text: String) -> String {
        let chars = Array(text)
        guard !chars.isEmpty else { return text }
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        var doubleOpen = true
        while i < chars.count {
            let c = chars[i]
            let prev = out.last
            let next = i + 1 < chars.count ? chars[i + 1] : nil

            if c == ".", i + 2 < chars.count, chars[i + 1] == ".", chars[i + 2] == "." {
                out.append("…")
                i += 3
                continue
            }

            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                let afterDash = i + 2 < chars.count ? chars[i + 2] : nil
                if isEmDashContext(before: prev, after: afterDash) {
                    out.append("—")
                    i += 2
                    continue
                }
            }

            if c == "\"" {
                if let prev, prev.isNumber {
                    out.append("\"")
                } else {
                    out.append(doubleOpen ? "\u{201C}" : "\u{201D}")
                    doubleOpen.toggle()
                }
                i += 1
                continue
            }

            if c == "'" {
                if isApostrophe(before: prev, after: next) {
                    out.append("\u{2019}")
                    i += 1
                    continue
                }
            }

            out.append(c)
            i += 1
        }
        return String(out)
    }

    static func applyPresentation(to attributed: inout AttributedString) {
        var rebuilt = AttributedString()
        for run in attributed.runs {
            let original = String(attributed.characters[run.range])
            let skip = run.inlinePresentationIntent?.contains(.code) == true || run.link != nil
            let text = skip ? original : present(original)
            rebuilt += AttributedString(text, attributes: run.attributes)
        }
        attributed = rebuilt
    }

    private static func isEmDashContext(before: Character?, after: Character?) -> Bool {
        func boundary(_ ch: Character?) -> Bool {
            guard let ch else { return true }
            return ch.isWhitespace || ".,;:!?)]}".contains(ch)
        }
        func flagStart(_ ch: Character?) -> Bool {
            guard let ch else { return false }
            return ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
        }
        // `--force`, `--no-verify`, `git--foo` stay ASCII.
        if flagStart(after) { return false }
        if let before, before.isLetter || before.isNumber || before == "_" { return false }
        return boundary(before) && boundary(after)
    }

    private static func isApostrophe(before: Character?, after: Character?) -> Bool {
        if let before, before.isNumber, let after, after.isNumber { return false }
        if let before, before.isLetter, let after, after.isLetter { return true }
        if let before, before.isLetter,
           after == nil || after?.isWhitespace == true || after.map({ ".,;:!?".contains($0) }) == true {
            return true
        }
        return false
    }
}

extension View {
    /// Caps prose at the reading measure. No-op on a narrower iPhone portrait.
    func aliceProseMeasure() -> some View {
        modifier(AliceProseMeasure())
    }

    func aliceProseLeading() -> some View {
        modifier(AliceProseLeading())
    }
}

private struct AliceProseMeasure: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.frame(maxWidth: measure, alignment: .leading)
    }

    private var measure: CGFloat {
        _ = dynamicTypeSize
        return AliceReading.proseMeasure()
    }
}

private struct AliceProseLeading: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.lineSpacing(leading)
    }

    private var leading: CGFloat {
        _ = dynamicTypeSize
        return AliceReading.extraLeading()
    }
}
