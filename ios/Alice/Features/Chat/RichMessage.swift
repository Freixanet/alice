import SwiftUI
import UIKit

// MARK: - What a reply is made of

/// A reply laid out as blocks, so it reads like the document it is.
///
/// SwiftUI's own Markdown support is inline only: headings, tables, quotes and
/// code came out as plain lines with bold here and there. The blocks are parsed
/// here, line by line and without a dependency, and each is drawn as what it is.
enum RichBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([RichListItem])
    case callout(RichCallout?, body: String)
    case code(language: String?, text: String)
    case table(RichTable)
    case rule
    case math(String)
    case buttons([RichReplyButton])
    case links([RichLink])
}

struct RichListItem: Equatable {
    enum Marker: Equatable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }

    let depth: Int
    let marker: Marker
    let text: String
}

/// GitHub's alert kinds: `> [!NOTE]` and friends.
enum RichCallout: String, Equatable, CaseIterable {
    case note, tip, important, warning, caution
}

struct RichTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]
}

/// A web link, drawn as a button that opens it: the address itself never shows.
struct RichLink: Equatable, Hashable {
    let title: String
    let url: URL
}

/// `[Title](alice://reply?text=…)`: a button that sends its text in the chat.
struct RichReplyButton: Equatable {
    let title: String
    let reply: String
}

// MARK: - Parsing

enum RichMarkdown {
    static func blocks(_ source: String) -> [RichBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [RichBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fence(trimmed) {
                var body: [String] = []
                index += 1
                // An unclosed fence is a reply still being written: everything
                // after it is code until the closing line arrives.
                while index < lines.count {
                    let current = lines[index]
                    index += 1
                    if current.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) { break }
                    body.append(current)
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("$$") {
                let rest = String(trimmed.dropFirst(2))
                if let end = rest.range(of: "$$") {
                    blocks.append(.math(String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)))
                    index += 1
                    continue
                }
                var body = rest.isEmpty ? [] : [rest]
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    index += 1
                    if let end = current.range(of: "$$") {
                        body.append(String(current[..<end.lowerBound]))
                        break
                    }
                    body.append(current)
                }
                let formula = body.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                blocks.append(.math(formula))
                continue
            }

            if let heading = heading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.contains("|"), index + 1 < lines.count,
               let alignments = tableSeparator(lines[index + 1]) {
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(fitted(cells(row), to: header.count, filler: ""))
                    index += 1
                }
                var links: [RichLink] = []
                func cell(_ text: String) -> String {
                    let extracted = RichLinks.extract(text)
                    links += extracted.links
                    return extracted.text
                }
                blocks.append(.table(RichTable(
                    header: header.map(cell),
                    alignments: fitted(alignments, to: header.count, filler: .leading),
                    rows: rows.map { $0.map(cell) }
                )))
                if !links.isEmpty { blocks.append(.links(RichLinks.unique(links))) }
                continue
            }

            if trimmed.hasPrefix(">") {
                var body: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var content = String(current.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    body.append(content)
                    index += 1
                }
                switch quoteKind(in: &body) {
                case .callout(let kind):
                    blocks.append(.callout(kind, body: body.joined(separator: "\n")))
                case .unknown:
                    // An unlisted [!KIND] is dropped, not drawn as a grey quote
                    // with the tag still in it. What remains is ordinary prose.
                    for run in paragraphRuns(body.joined(separator: "\n")) {
                        blocks.append(.paragraph(run))
                    }
                case .quote:
                    blocks.append(.callout(nil, body: body.joined(separator: "\n")))
                }
                continue
            }

            if let first = listItem(line) {
                var items = [first]
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line ends the list unless another item follows.
                        if index + 1 < lines.count, listItem(lines[index + 1]) != nil {
                            index += 1
                            continue
                        }
                        break
                    }
                    if let next = listItem(current) {
                        items.append(next)
                        index += 1
                        continue
                    }
                    if leadingSpaces(current) >= 2, let last = items.popLast() {
                        let text = last.text + "\n" + current.trimmingCharacters(in: .whitespaces)
                        items.append(RichListItem(depth: last.depth, marker: last.marker, text: text))
                        index += 1
                        continue
                    }
                    break
                }
                if let buttons = onlyReplyButtons(items.map(\.text)) {
                    blocks.append(.buttons(buttons))
                } else {
                    var links: [RichLink] = []
                    let cleaned = items.compactMap { item -> RichListItem? in
                        let extracted = RichLinks.extract(item.text)
                        links += extracted.links
                        guard !extracted.text.isEmpty else { return nil }
                        return RichListItem(depth: item.depth, marker: item.marker, text: extracted.text)
                    }
                    if !cleaned.isEmpty { blocks.append(.list(cleaned)) }
                    if !links.isEmpty { blocks.append(.links(RichLinks.unique(links))) }
                }
                continue
            }

            var paragraph = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let following = index + 1 < lines.count ? lines[index + 1] : nil
                if next.trimmingCharacters(in: .whitespaces).isEmpty || startsBlock(next, following: following) {
                    break
                }
                paragraph.append(next.trimmingCharacters(in: .whitespaces))
                index += 1
            }
            let extracted = replyButtons(in: paragraph.joined(separator: "\n"))
            let linked = RichLinks.extract(extracted.text)
            for run in paragraphRuns(linked.text) {
                blocks.append(.paragraph(run))
            }
            if !linked.links.isEmpty {
                blocks.append(.links(linked.links))
            }
            if !extracted.buttons.isEmpty {
                blocks.append(.buttons(extracted.buttons))
            }
        }
        return blocks
    }

    /// Parsed replies by content, because a chat redraws every visible row.
    @MainActor private static var cache: [String: [RichBlock]] = [:]

    @MainActor static func cached(_ content: String) -> [RichBlock] {
        if let hit = cache[content] { return hit }
        let parsed = blocks(content)
        if cache.count >= 300 { cache.removeAll(keepingCapacity: true) }
        cache[content] = parsed
        return parsed
    }

    // MARK: Pieces

    private static func fence(_ trimmed: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (marker, language.isEmpty ? nil : language)
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> RichBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: hashes, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        let placeholder = "\u{0}"
        return row.replacingOccurrences(of: "\\|", with: placeholder)
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func tableSeparator(_ line: String) -> [RichTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var alignments: [RichTable.Alignment] = []
        for part in parts {
            let dashes = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func fitted<T>(_ values: [T], to count: Int, filler: T) -> [T] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: filler, count: count - values.count)
    }

    private enum QuoteKind {
        case callout(RichCallout)
        case unknown
        case quote
    }

    /// GitHub callouts Alice draws: NOTE, TIP, IMPORTANT, WARNING, CAUTION.
    /// Any other `[!KIND]` is discarded so it is never a half-drawn card.
    private static func quoteKind(in body: inout [String]) -> QuoteKind {
        guard let first = body.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("[!"), let close = first.firstIndex(of: "]")
        else { return .quote }
        let name = String(first[first.index(first.startIndex, offsetBy: 2)..<close]).lowercased()
        let after = first[first.index(after: close)...].trimmingCharacters(in: .whitespaces)
        body.removeFirst()
        if !after.isEmpty { body.insert(after, at: 0) }
        if let kind = RichCallout(rawValue: name) { return .callout(kind) }
        return .unknown
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }

    static func listItem(_ line: String) -> RichListItem? {
        let depth = min(leadingSpaces(line) / 2, 4)
        let content = line.trimmingCharacters(in: .whitespaces)
        guard let first = content.first else { return nil }

        if "-*+".contains(first), content.dropFirst().first == " " {
            var text = String(content.dropFirst(2))
            var marker = RichListItem.Marker.bullet
            let lowered = text.lowercased()
            if lowered.hasPrefix("[ ] ") || lowered.hasPrefix("[x] ") {
                marker = .task(done: lowered.hasPrefix("[x]"))
                text = String(text.dropFirst(4))
            }
            return RichListItem(depth: depth, marker: marker, text: text)
        }

        let digits = content.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let rest = content.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")",
              rest.dropFirst().first == " "
        else { return nil }
        return RichListItem(depth: depth, marker: .number(number), text: String(rest.dropFirst(2)))
    }

    /// Lines without a blank line between them are one paragraph, the way
    /// Markdown reads them. Only a truly long wall is split at its sentences.
    static func paragraphRuns(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let joined = trimmed.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let source = joined.isEmpty ? trimmed : joined
        return breathe(source)
    }

    private static let abbreviations: Set<String> = [
        "sr", "sra", "srta", "dr", "dra", "etc", "ej", "vs", "n", "p", "d", "ee",
    ]

    /// A very long wall still breaks where a new sentence starts. Short text
    /// is left alone: splitting it would read in fits and starts.
    static func breathe(_ line: String) -> [String] {
        guard line.count >= 280 else { return [line] }
        var parts: [String] = []
        var start = line.startIndex
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if ".!?".contains(character) {
                let after = line.index(after: index)
                if after < line.endIndex, line[after] == " " {
                    let next = line.index(after: after)
                    if next < line.endIndex, isSentenceStart(line[next]),
                       !isAbbreviation(line, period: index) {
                        let chunk = String(line[start..<after])
                            .trimmingCharacters(in: .whitespaces)
                        if !chunk.isEmpty { parts.append(chunk) }
                        start = next
                        index = next
                        continue
                    }
                }
            }
            index = line.index(after: index)
        }
        let tail = String(line[start...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts.count >= 2 ? parts : [line]
    }

    private static func isSentenceStart(_ character: Character) -> Bool {
        character.isUppercase || "¿¡".contains(character)
    }

    private static func isAbbreviation(_ line: String, period: String.Index) -> Bool {
        var start = period
        while start > line.startIndex {
            let previous = line.index(before: start)
            if line[previous].isLetter { start = previous } else { break }
        }
        guard start < period else { return false }
        return abbreviations.contains(String(line[start..<period]).lowercased())
    }

    private static func startsBlock(_ line: String, following: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if fence(trimmed) != nil || trimmed.hasPrefix("$$") || trimmed.hasPrefix(">") { return true }
        if heading(trimmed) != nil || isRule(trimmed) || listItem(line) != nil { return true }
        if trimmed.contains("|"), let following, tableSeparator(following) != nil { return true }
        return false
    }

    // MARK: Reply buttons

    private static let replyPattern = #"\[([^\]\n]+)\]\((alice://reply[^)\s]*)\)"#

    static func replyButtons(in text: String) -> (text: String, buttons: [RichReplyButton]) {
        guard text.contains("alice://reply"),
              let regex = try? NSRegularExpression(pattern: replyPattern)
        else { return (text, []) }
        let range = NSRange(text.startIndex..., in: text)
        var buttons: [RichReplyButton] = []
        var remaining = text
        // Back to front, so removing one match leaves the earlier ranges valid.
        for match in regex.matches(in: text, range: range).reversed() {
            guard let titleRange = Range(match.range(at: 1), in: text),
                  let linkRange = Range(match.range(at: 2), in: text),
                  let removal = Range(match.range, in: remaining)
            else { continue }
            let title = String(text[titleRange]).trimmingCharacters(in: .whitespaces)
            buttons.insert(
                RichReplyButton(title: title, reply: reply(from: String(text[linkRange]), title: title)),
                at: 0
            )
            remaining.removeSubrange(removal)
        }
        let cleaned = remaining.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (cleaned, buttons)
    }

    private static func onlyReplyButtons(_ texts: [String]) -> [RichReplyButton]? {
        var buttons: [RichReplyButton] = []
        for text in texts {
            let extracted = replyButtons(in: text)
            guard extracted.buttons.count == 1,
                  extracted.text.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            buttons += extracted.buttons
        }
        return buttons.isEmpty ? nil : buttons
    }

    private static func reply(from link: String, title: String) -> String {
        let text = URLComponents(string: link)?.queryItems?
            .first { $0.name == "text" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false ? text : nil) ?? title
    }
}

// MARK: - Links

/// Web links taken out of the text, to be drawn as buttons. A link written as
/// `[title](url)` keeps its title in the sentence; a bare address leaves the
/// text entirely, and a line that only introduced it ("Fuente: …") goes too.
/// Code is never touched.
enum RichLinks {
    private static let markdownLink = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^)\s]+)\)"#)
    private static let autolink = try? NSRegularExpression(pattern: #"<(https?://[^>\s]+)>"#)
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func extract(_ text: String) -> (text: String, links: [RichLink]) {
        let lowered = text.lowercased()
        guard lowered.contains("http") || lowered.contains("www.") else { return (text, []) }
        var links: [RichLink] = []
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            var withTitles = "", bare = "", found = false
            for (index, part) in line.components(separatedBy: "`").enumerated() {
                let tick = index == 0 ? "" : "`"
                guard index % 2 == 0 else {
                    withTitles += tick + part
                    bare += tick + part
                    continue
                }
                let stripped = strip(part, into: &links)
                found = found || stripped.found
                withTitles += tick + stripped.withTitles
                bare += tick + stripped.bare
            }
            guard found else {
                kept.append(line)
                continue
            }
            let label = bare.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "")
                .trimmingCharacters(in: .whitespaces)
            let introducesLink = label.hasSuffix(":") && label.split(separator: " ").count <= 3
            if tidy(bare).isEmpty || introducesLink { continue }
            let clean = tidy(withTitles)
            if !clean.isEmpty { kept.append(clean) }
        }
        return (kept.joined(separator: "\n"), unique(links))
    }

    static func unique(_ links: [RichLink]) -> [RichLink] {
        var seen = Set<String>()
        return links.filter { seen.insert($0.url.absoluteString).inserted }
    }

    private static func strip(
        _ text: String, into links: inout [RichLink]
    ) -> (withTitles: String, bare: String, found: Bool) {
        var withTitles = text, bare = text, found = false
        if let regex = markdownLink {
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: text, range: range) {
                guard let url = URL(string: ns.substring(with: match.range(at: 2))) else { continue }
                links.append(RichLink(title: title(ns.substring(with: match.range(at: 1)), url: url), url: url))
                found = true
            }
            withTitles = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
            bare = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        if let regex = autolink {
            let ns = bare as NSString
            for match in regex.matches(in: bare, range: NSRange(location: 0, length: ns.length)).reversed() {
                let whole = ns.substring(with: match.range)
                guard let url = URL(string: ns.substring(with: match.range(at: 1))) else { continue }
                links.append(RichLink(title: domain(url), url: url))
                found = true
                withTitles = withTitles.replacingOccurrences(of: whole, with: "")
                bare = bare.replacingOccurrences(of: whole, with: "")
            }
        }
        if let detector {
            let ns = bare as NSString
            for match in detector.matches(in: bare, range: NSRange(location: 0, length: ns.length)) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let raw = ns.substring(with: match.range)
                links.append(RichLink(title: domain(url), url: url))
                found = true
                withTitles = withTitles.replacingOccurrences(of: raw, with: "")
                bare = bare.replacingOccurrences(of: raw, with: "")
            }
        }
        return (withTitles, bare, found)
    }

    private static func tidy(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+([,.;!?])"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        while let last = text.last, "—–-·|→:".contains(last) {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func title(_ raw: String, url: URL) -> String {
        let clean = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return domain(url) }
        return clean.count > 60 ? String(clean.prefix(57)) + "…" : clean
    }

    static func domain(_ url: URL) -> String {
        let host = (url.host ?? url.absoluteString).lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Inline

/// A line of text with emphasis, links, underline and inline formulas.
enum RichInline {
    enum Segment: Equatable {
        case text(String)
        case underline(String)
        case math(String)
    }

    /// `<u>…</u>` and `$…$`. Markdown has no underline, and a currency amount
    /// ("$5 y $10") is not a formula: the dollars must hug their content.
    static func segments(_ text: String) -> [Segment] {
        let pattern = #"<u>(.+?)</u>|(?<![\\$\w])\$(?!\s)([^$\n]+?)(?<!\s)\$(?![\w$])"#
        guard (text.contains("<u>") || text.contains("$")),
              let regex = try? NSRegularExpression(pattern: pattern)
        else { return [.text(text)] }
        var segments: [Segment] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            if let underlined = Range(match.range(at: 1), in: text) {
                if cursor < whole.lowerBound { segments.append(.text(String(text[cursor..<whole.lowerBound]))) }
                segments.append(.underline(String(text[underlined])))
                cursor = whole.upperBound
            } else if let formula = Range(match.range(at: 2), in: text) {
                let content = String(text[formula])
                // Plain numbers between dollars stay text.
                guard content.contains(where: { $0.isLetter || "\\^_=+-*/".contains($0) }),
                      !content.allSatisfy({ $0.isNumber || ".,".contains($0) })
                else { continue }
                if cursor < whole.lowerBound { segments.append(.text(String(text[cursor..<whole.lowerBound]))) }
                segments.append(.math(content))
                cursor = whole.upperBound
            }
        }
        if cursor < text.endIndex { segments.append(.text(String(text[cursor...]))) }
        return segments.isEmpty ? [.text(text)] : segments
    }

    @MainActor static func attributed(_ text: String, body: Color, link: Color) -> AttributedString {
        var output = AttributedString()
        for segment in segments(text) {
            switch segment {
            case let .text(piece):
                output += MessageRow.linkified(MessageRow.parsed(piece), body: body, link: link)
            case let .underline(piece):
                var run = MessageRow.linkified(MessageRow.parsed(piece), body: body, link: link)
                run.underlineStyle = .single
                output += run
            case let .math(formula):
                var run = AttributedString(RichMath.unicode(formula))
                run.font = .system(.body, design: .serif).italic()
                run.foregroundColor = body
                output += run
            }
        }
        return output
    }

    private struct Key: Hashable {
        let text: String
        let failed: Bool
        let link: Color
    }

    @MainActor private static var cache: [Key: AttributedString] = [:]

    @MainActor static func cached(_ text: String, failed: Bool, link: Color) -> AttributedString {
        let key = Key(text: text, failed: failed, link: link)
        if let hit = cache[key] { return hit }
        let fresh = attributed(text, body: failed ? .red : .primary, link: link)
        if cache.count >= 800 { cache.removeAll(keepingCapacity: true) }
        cache[key] = fresh
        return fresh
    }
}

// MARK: - Formulas

/// Simple LaTeX as readable Unicode: fractions, powers, roots, Greek letters
/// and the common operators. Not typesetting — a formula a phone can show
/// without a web view, and that still reads correctly when copied.
enum RichMath {
    static func unicode(_ latex: String) -> String {
        let characters = Array(latex)
        var index = 0
        return render(characters, &index, until: nil)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func render(_ c: [Character], _ i: inout Int, until closing: Character?) -> String {
        var out = ""
        while i < c.count {
            let character = c[i]
            if let closing, character == closing {
                i += 1
                return out
            }
            switch character {
            case "\\":
                i += 1
                out += command(readCommand(c, &i), c, &i)
            case "^":
                i += 1
                out += raised(argument(c, &i))
            case "_":
                i += 1
                out += lowered(argument(c, &i))
            case "{":
                i += 1
                out += render(c, &i, until: "}")
            case "}":
                i += 1
            default:
                out.append(character)
                i += 1
            }
        }
        return out
    }

    private static func argument(_ c: [Character], _ i: inout Int) -> String {
        while i < c.count, c[i] == " " { i += 1 }
        guard i < c.count else { return "" }
        if c[i] == "{" {
            i += 1
            return render(c, &i, until: "}")
        }
        if c[i] == "\\" {
            i += 1
            return command(readCommand(c, &i), c, &i)
        }
        defer { i += 1 }
        return String(c[i])
    }

    private static func readCommand(_ c: [Character], _ i: inout Int) -> String {
        guard i < c.count else { return "" }
        guard c[i].isLetter else {
            defer { i += 1 }
            return String(c[i])
        }
        var name = ""
        while i < c.count, c[i].isLetter {
            name.append(c[i])
            i += 1
        }
        return name
    }

    private static func command(_ name: String, _ c: [Character], _ i: inout Int) -> String {
        switch name {
        case "frac", "dfrac", "tfrac":
            let top = argument(c, &i)
            let bottom = argument(c, &i)
            return "\(grouped(top))/\(grouped(bottom))"
        case "sqrt":
            var degree = ""
            if i < c.count, c[i] == "[" {
                i += 1
                while i < c.count, c[i] != "]" {
                    degree.append(c[i])
                    i += 1
                }
                i += 1
            }
            return (degree.isEmpty ? "" : raised(degree)) + "√" + grouped(argument(c, &i))
        case "text", "mathrm", "mathbf", "mathit", "textbf", "textit", "operatorname", "mbox", "boldsymbol":
            return argument(c, &i)
        case "left", "right", "big", "Big", "bigl", "bigr", "Bigl", "Bigr", "displaystyle", "!":
            return ""
        case ",", ";", ":", " ", "quad", "qquad":
            return " "
        default:
            return symbols[name] ?? name
        }
    }

    private static func grouped(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let simple = trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "," }
        return simple ? trimmed : "(\(trimmed))"
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "k": "ᵏ", "t": "ᵗ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ",
        "i": "ᵢ", "j": "ⱼ", "n": "ₙ", "t": "ₜ", "k": "ₖ", "m": "ₘ", "p": "ₚ", "s": "ₛ",
    ]

    private static func raised(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let mapped = trimmed.compactMap { superscripts[$0] }
        if !trimmed.isEmpty, mapped.count == trimmed.count { return String(mapped) }
        return trimmed.count == 1 ? "^" + trimmed : "^(\(trimmed))"
    }

    private static func lowered(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let mapped = trimmed.compactMap { subscripts[$0] }
        if !trimmed.isEmpty, mapped.count == trimmed.count { return String(mapped) }
        return trimmed.count == 1 ? "_" + trimmed : "_(\(trimmed))"
    }

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "Gamma": "Γ", "delta": "δ", "Delta": "Δ",
        "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "Theta": "Θ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "Lambda": "Λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "Pi": "Π", "rho": "ρ", "sigma": "σ", "Sigma": "Σ", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "Phi": "Φ", "chi": "χ", "psi": "ψ", "Psi": "Ψ", "omega": "ω", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈",
        "equiv": "≡", "sim": "∼", "propto": "∝", "ll": "≪", "gg": "≫",
        "infty": "∞", "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇",
        "to": "→", "rightarrow": "→", "Rightarrow": "⇒", "leftarrow": "←", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "mapsto": "↦",
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩",
        "forall": "∀", "exists": "∃", "emptyset": "∅", "neg": "¬", "land": "∧", "lor": "∨",
        "cdots": "⋯", "ldots": "…", "dots": "…", "circ": "∘", "degree": "°", "prime": "′",
        "%": "%", "$": "$", "{": "{", "}": "}", "&": "&", "#": "#", "_": "_",
    ]
}

// MARK: - Drawing

/// A reply drawn block by block.
struct RichMessageView: View {
    @Environment(\.colorScheme) private var scheme
    let content: String
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(RichMarkdown.cached(content).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        RichInline.cached(text, failed: failed, link: Palette.link(scheme))
    }

    @ViewBuilder
    private func view(for block: RichBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 4 : 0)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(inline(text))
                .lineSpacing(4)
                .textSelection(.enabled)
                .tint(Palette.link(scheme))
        case let .list(items):
            RichListView(items: items, inline: inline)
        case let .callout(kind, body):
            RichCalloutView(kind: kind, content: body, failed: failed)
        case let .code(language, text):
            RichCodeView(language: language, code: text)
        case let .table(table):
            RichTableView(table: table, inline: inline)
        case .rule:
            Divider().padding(.vertical, 2)
        case let .math(formula):
            Text(RichMath.unicode(formula))
                .font(.system(.title3, design: .serif))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
                .accessibilityLabel(formula)
        case let .buttons(buttons):
            RichReplyButtonsView(buttons: buttons)
        case let .links(links):
            RichLinksView(links: links)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.bold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct RichListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let items: [RichListItem]
    let inline: (String) -> AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(item)
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(inline(item.text))
                        .textSelection(.enabled)
                        .tint(Palette.link(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: RichListItem) -> some View {
        switch item.marker {
        case .bullet:
            Text(item.depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
        case let .number(number):
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
        case let .task(done):
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .imageScale(.small)
                .foregroundStyle(done ? store.accent.primary(scheme) : Color.secondary)
                .accessibilityLabel(done ? "Done" : "To do")
        }
    }
}

private struct RichCalloutView: View {
    @Environment(\.colorScheme) private var scheme
    let kind: RichCallout?
    let content: String
    let failed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                if let kind {
                    Label(Self.title(kind), systemImage: Self.icon(kind))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                // A callout holds Markdown of its own.
                AnyView(RichMessageView(content: content, failed: failed))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch kind {
        case .note: .blue
        case .tip: .green
        case .important: .purple
        case .warning: .orange
        case .caution: .red
        case nil: .secondary
        }
    }

    static func title(_ kind: RichCallout) -> String {
        switch kind {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }

    static func icon(_ kind: RichCallout) -> String {
        switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }
}

private struct RichCodeView: View {
    @Environment(\.colorScheme) private var scheme
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
    }
}

private struct RichTableView: View {
    @Environment(\.colorScheme) private var scheme
    let table: RichTable
    let inline: (String) -> AttributedString

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        Text(inline(cell))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: 240, alignment: frame(column))
                            .gridColumnAlignment(horizontal(column))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            Text(inline(cell))
                                .font(.subheadline)
                                .textSelection(.enabled)
                                .frame(maxWidth: 240, alignment: frame(column))
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Palette.card(scheme), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.border(scheme), lineWidth: 0.5)
        }
    }

    private func alignment(_ column: Int) -> RichTable.Alignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }

    private func horizontal(_ column: Int) -> HorizontalAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frame(_ column: Int) -> Alignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Web links as buttons that open them, never as addresses in the text.
private struct RichLinksView: View {
    let links: [RichLink]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { items }
            VStack(alignment: .leading, spacing: 8) { items }
        }
    }

    @ViewBuilder
    private var items: some View {
        ForEach(links, id: \.self) { link in
            Link(destination: link.url) {
                Text(link.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 7))
            .controlSize(.small)
            .tint(.primary)
            .accessibilityHint("Opens \(RichLinks.domain(link.url))")
        }
    }
}

/// Reply buttons: each sends its text in the chat on screen, as if typed.
private struct RichReplyButtonsView: View {
    @Environment(AppStore.self) private var store
    let buttons: [RichReplyButton]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { items }
            VStack(alignment: .leading, spacing: 8) { items }
        }
    }

    @ViewBuilder
    private var items: some View {
        ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
            Button(button.title) {
                store.sendQuickReply(button.reply)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .disabled(store.isSending)
            .accessibilityHint("Sends “\(button.reply)”")
        }
    }
}
