import SwiftUI

/// A reply while it is still arriving, laid out as it will be once it lands.
///
/// Laying the whole answer out again on every token is what once made the
/// phone stop taking taps, so plain text stood in until the end — and the
/// reply read as raw Markdown, `###` and `[title](https://…)` included, then
/// jumped into shape. Here what has been finished — every block up to the
/// last blank line — is drawn by `RichMessageView`, whose parse is cached and
/// so runs once per block; only the paragraph being written is redrawn per
/// token, as light inline Markdown. A code or card block still open, or a
/// table still being written, stays out of sight until it is whole.
struct StreamingReply: View {
    let content: String
    var onTap: (@MainActor () -> Void)? = nil

    var body: some View {
        let parts = Self.split(content)
        VStack(alignment: .leading, spacing: 14) {
            if !parts.finished.isEmpty {
                RichMessageView(content: parts.finished, onTap: onTap)
            }
            if !parts.writing.isEmpty {
                Self.tailText(parts.writing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The paragraph being written: a heading as a heading, the rest as
    /// body text with bold, italics, code and links.
    private static func tailText(_ tail: String) -> some View {
        let heading = tail.prefix(while: { $0 == "#" }).count
        let isHeading = (1...6).contains(heading) && tail.dropFirst(heading).first == " "
        let text = isHeading ? String(tail.dropFirst(heading + 1)) : tail
        return Text(inline(text))
            .font(isHeading ? (heading <= 2 ? .title3.weight(.semibold) : .headline) : .body)
            .lineSpacing(isHeading ? 2 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }

    /// `finished`: whole blocks, up to the last blank line outside a code
    /// block. `writing`: what follows, without an unclosed code or card block
    /// or a table still growing.
    nonisolated static func split(_ content: String) -> (finished: String, writing: String) {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var inFence = false
        var fenceStart: Int?
        var boundary = 0 // lines before this index are finished
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                fenceStart = inFence ? index : nil
                continue
            }
            if !inFence, trimmed.isEmpty { boundary = index }
        }
        let finished = lines[..<boundary].joined(separator: "\n")
        var writingLines = Array(lines[min(boundary, lines.count)...])
        if inFence, let fenceStart, fenceStart >= boundary {
            writingLines = Array(lines[boundary..<fenceStart])
        }
        var writing = writingLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A table reads as rows of pipes until it is complete.
        if writing.hasPrefix("|") { writing = "" }
        return (finished.trimmingCharacters(in: .whitespacesAndNewlines), writing)
    }
}
