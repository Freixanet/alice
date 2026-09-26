import Foundation

/// One occurrence selected from the @ menu. A slug alone cannot distinguish
/// that occurrence from the same name typed later as ordinary prose.
struct DraftMention: Hashable, Sendable, Codable {
    let display: String
    let slug: String
    var location: Int

    var utf16Range: NSRange {
        NSRange(location: location, length: display.utf16.count)
    }

    func range(in text: String) -> Range<String.Index>? {
        guard let range = Range(utf16Range, in: text),
              String(text[range]).caseInsensitiveCompare(display) == .orderedSame,
              ConversationTitle.isWord(range, in: text)
        else { return nil }
        return range
    }

    static func rebased(_ mentions: [Self], from old: String, to new: String) -> [Self] {
        // Pasting around an unchanged draft can add text on both sides at
        // once. A suffix-only diff can otherwise confuse a selected name
        // with the same plain word appended later.
        if !old.isEmpty, let kept = new.range(of: old) {
            let shift = NSRange(kept, in: new).location
            let carried = mentions.compactMap { mention -> Self? in
                var moved = mention
                moved.location += shift
                return moved.range(in: new) == nil ? nil : moved
            }
            if carried.count == mentions.count { return carried }
        }
        let before = Array(old.utf16)
        let after = Array(new.utf16)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        let oldEnd = before.count - suffix
        let newEnd = after.count - suffix
        return mentions.compactMap { mention in
            var moved = mention
            if mention.location >= oldEnd {
                moved.location += newEnd - oldEnd
            } else if NSMaxRange(mention.utf16Range) > prefix {
                // The edit touched the selected name; it is ordinary text now.
                return nil
            }
            return moved.range(in: new) == nil ? nil : moved
        }
    }
}
