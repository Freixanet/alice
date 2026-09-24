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
            let tail = Self.stabilized(parts.writing)
            if !tail.isEmpty {
                // The same drawing as the finished reply, so nothing changes
                // shape when the paragraph completes. Parsed fresh — it is one
                // paragraph — and never cached, so it does not crowd out the
                // finished blocks.
                RichMessageView(content: tail, onTap: onTap, cachesParse: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The paragraph being written, as it can be drawn with the final look:
    /// a bold or code span still open is closed, so it is bold as it is typed
    /// instead of showing asterisks; a link, button or callout still being
    /// written shows only its words, or nothing; a line that is so far only a
    /// list or heading marker waits for its words.
    nonisolated static func stabilized(_ tail: String) -> String {
        var text = tail
        if let open = text.range(of: "[", options: .backwards) {
            let after = text[open.lowerBound...]
            let complete = after.range(of: #"^\[[^\]]*\]\([^)\s]*\)"#, options: .regularExpression) != nil
            if !complete {
                let before = String(text[..<open.lowerBound])
                let isBang = before.hasSuffix("!")
                if after.hasPrefix("[!") || after.contains("alice://") || isBang {
                    // A callout label, an image, or a button: nothing until whole.
                    text = isBang ? String(before.dropLast()) : before
                } else if let close = after.firstIndex(of: "]") {
                    text = before + after[after.index(after: after.startIndex)..<close]
                } else {
                    text = before + after.dropFirst()
                }
            }
        }
        var lines = text.components(separatedBy: "\n")
        if let last = lines.last?.trimmingCharacters(in: .whitespaces),
           last.range(of: #"^([-*+>]|#{1,6}|\d{1,3}[.)])$"#, options: .regularExpression) != nil {
            lines.removeLast()
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.components(separatedBy: "**").count % 2 == 0 {
            text = text.hasSuffix("**") ? String(text.dropLast(2)) : text + "**"
        }
        if text.filter({ $0 == "`" }).count % 2 == 1 { text += "`" }
        return text
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
