import UIKit

/// Where a photo or file lands in a note: its own line, relative to the caret.
///
/// At the start of a line it goes above; at the end of the line's words it
/// goes below; in the middle it splits the line. An empty line takes it.
enum NoteInlineInsert {
    struct Plan: Equatable {
        var location: Int
        var prefix: String
        var suffix: String
    }

    static func plan(caret: Int, in string: String) -> Plan {
        let ns = string as NSString
        let length = ns.length
        let caret = max(0, min(caret, length))
        if length == 0 {
            return Plan(location: 0, prefix: "", suffix: "\n")
        }
        let probe = caret == length ? length - 1 : caret
        let paragraph = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        let endsWithNewline = paragraph.length > 0
            && ns.character(at: paragraph.location + paragraph.length - 1) == 10
        let contentEnd = endsWithNewline
            ? paragraph.location + paragraph.length - 1
            : paragraph.location + paragraph.length
        let atStart = caret == paragraph.location
        let atEnd = caret >= contentEnd
        if atStart && atEnd {
            return Plan(location: caret, prefix: "", suffix: "")
        }
        if atStart {
            return Plan(location: caret, prefix: "", suffix: "\n")
        }
        if atEnd {
            return Plan(location: caret, prefix: "\n", suffix: caret == length ? "\n" : "")
        }
        return Plan(location: caret, prefix: "\n", suffix: "\n")
    }

    /// Deletes a photo sitting in `range`, or the one just before the caret
    /// when the keyboard skipped it. True when this handled the key.
    @MainActor
    static func deleteAttachment(in view: UITextView, range: NSRange) -> Bool {
        let storage = view.textStorage
        func isAttachment(at index: Int) -> Bool {
            guard index >= 0, index < storage.length else { return false }
            if storage.attribute(.attachment, at: index, effectiveRange: nil) != nil { return true }
            return (storage.string as NSString).character(at: index) == 0xFFFC
        }
        var target: NSRange?
        if range.length > 0, range.location < storage.length {
            let end = min(range.location + range.length, storage.length)
            var index = range.location
            while index < end {
                if isAttachment(at: index) {
                    target = range
                    break
                }
                index += 1
            }
        }
        if target == nil {
            let caret = view.selectedRange.length == 0
                ? view.selectedRange.location
                : range.location + range.length
            if caret > 0, isAttachment(at: caret - 1) {
                target = NSRange(location: caret - 1, length: 1)
            }
        }
        guard let target, target.length > 0,
              target.location + target.length <= storage.length
        else { return false }
        var found = false
        storage.enumerateAttribute(.attachment, in: target) { value, _, stop in
            if value is NSTextAttachment {
                found = true
                stop.pointee = true
            }
        }
        if !found {
            let ns = storage.string as NSString
            for index in target.location..<(target.location + target.length)
            where ns.character(at: index) == 0xFFFC {
                found = true
                break
            }
        }
        guard found else { return false }
        storage.replaceCharacters(in: target, with: "")
        view.selectedRange = NSRange(location: target.location, length: 0)
        return true
    }

    @MainActor
    static func insert(_ item: Attachment, into view: UITextView) {
        let selected = view.selectedRange
        if selected.length > 0 {
            view.textStorage.replaceCharacters(in: selected, with: "")
            view.selectedRange = NSRange(location: selected.location, length: 0)
        }
        let caret = view.selectedRange.location
        let plan = plan(caret: caret, in: view.textStorage.string)
        let typing = view.typingAttributes
        let block = NSMutableAttributedString()
        if !plan.prefix.isEmpty {
            block.append(NSAttributedString(string: plan.prefix, attributes: typing))
        }
        block.append(NSAttributedString(attachment: NoteInlineAttachment(item: item)))
        if !plan.suffix.isEmpty {
            block.append(NSAttributedString(string: plan.suffix, attributes: typing))
        }
        view.textStorage.replaceCharacters(in: NSRange(location: plan.location, length: 0), with: block)
        let after = plan.location + block.length
        view.selectedRange = NSRange(location: after, length: 0)
        view.scrollRangeToVisible(view.selectedRange)
        view.delegate?.textViewDidChange?(view)
    }

    /// RTF cannot carry the bytes; a replacement character marks the place.
    static func replaceAttachmentsWithPlaceholders(in text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.attachment, in: whole, options: .reverse) { value, range, _ in
            guard value is NSTextAttachment else { return }
            text.replaceCharacters(in: range, with: "\u{FFFC}")
        }
    }

    /// The photos and files in document order, as they sit in the text.
    static func attachments(in text: NSAttributedString) -> [Attachment] {
        var items: [Attachment] = []
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.attachment, in: whole) { value, _, _ in
            if let inline = value as? NoteInlineAttachment {
                items.append(inline.item)
            }
        }
        return items
    }

    /// Words an agent can read: the object-replacement characters are gone.
    static func words(from text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Puts stored files back on their replacement characters, or after the
    /// words when an older note never recorded a place.
    static func embedding(_ items: [Attachment], in styled: NSAttributedString) -> NSAttributedString {
        guard !items.isEmpty else { return styled }
        let copy = NSMutableAttributedString(attributedString: styled)
        var index = 0
        var location = 0
        while location < copy.length, index < items.count {
            let ch = (copy.string as NSString).character(at: location)
            let existing = copy.attribute(.attachment, at: location, effectiveRange: nil)
            if existing is NSTextAttachment || ch == 0xFFFC {
                copy.replaceCharacters(
                    in: NSRange(location: location, length: 1),
                    with: NSAttributedString(attachment: NoteInlineAttachment(item: items[index]))
                )
                index += 1
            }
            location += 1
        }
        let body: [NSAttributedString.Key: Any] = [
            .font: RichNote.bodyFont, .foregroundColor: UIColor.label,
        ]
        while index < items.count {
            if copy.length > 0 {
                let last = (copy.string as NSString).character(at: copy.length - 1)
                if last != 10 {
                    copy.append(NSAttributedString(string: "\n", attributes: body))
                }
            }
            copy.append(NSAttributedString(attachment: NoteInlineAttachment(item: items[index])))
            index += 1
        }
        return copy
    }
}

/// A photo or file drawn on its own line in the note.
final class NoteInlineAttachment: NSTextAttachment {
    let item: Attachment

    init(item: Attachment) {
        self.item = item
        super.init(data: nil, ofType: nil)
        if item.kind == .image, let picture = UIImage(data: item.data) {
            image = picture
        } else {
            image = Self.fileChip(named: item.name)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let maxWidth = lineFrag.width > 8 ? lineFrag.width - 4 : 320
        guard let image else {
            return CGRect(x: 0, y: 0, width: min(280, maxWidth), height: 56)
        }
        if item.kind == .file {
            let width = min(image.size.width, maxWidth)
            return CGRect(x: 0, y: 0, width: width, height: image.size.height)
        }
        let ratio = image.size.height / max(image.size.width, 1)
        let width = min(image.size.width, maxWidth)
        return CGRect(x: 0, y: 0, width: width, height: (width * ratio).rounded())
    }

    private static func fileChip(named name: String) -> UIImage {
        let size = CGSize(width: 280, height: 56)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
            UIColor.secondarySystemFill.setFill()
            path.fill()
            UIColor.separator.setStroke()
            path.lineWidth = 1
            path.stroke()
            let icon = UIImage(systemName: "doc")?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            icon?.draw(in: CGRect(x: 16, y: 14, width: 28, height: 28))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .subheadline),
                .foregroundColor: UIColor.label,
            ]
            (name as NSString).draw(
                with: CGRect(x: 52, y: 16, width: 212, height: 24),
                options: .usesLineFragmentOrigin, attributes: attrs, context: nil
            )
        }
    }
}
