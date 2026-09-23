import SwiftUI
import UIKit

/// The draft's glyphs and insertion point must come from the same text view.
/// A separate styled overlay drifts as soon as one word uses a different font weight.
struct MentionDraftEditor: UIViewRepresentable {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var mentionedRanges: @MainActor (String) -> [Range<String.Index>]

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focused: focused, mentionedRanges: mentionedRanges)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.showsVerticalScrollIndicator = false
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "composer.draft"
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focused = focused
        context.coordinator.mentionedRanges = mentionedRanges

        let font = UIFont.preferredFont(forTextStyle: .body)
        let rendered = DraftMentionStyle.render(text, ranges: mentionedRanges(text), font: font)
        let typing: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.label
        ]

        if view.text != text {
            let previous = view.text ?? ""
            let selection = view.selectedRange
            context.coordinator.updatingFromModel = true
            view.attributedText = rendered
            view.selectedRange = DraftSelection.remap(selection, from: previous, to: text)
            context.coordinator.updatingFromModel = false
        } else if view.markedTextRange == nil && !view.attributedText.isEqual(to: rendered) {
            // Change attributes in place: replacing attributedText on each keypress
            // resets UIKit's selection, marked text and undo history.
            let selection = view.selectedRange
            context.coordinator.updatingFromModel = true
            view.textStorage.beginEditing()
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) {
                attributes, range, _ in
                view.textStorage.setAttributes(attributes, range: range)
            }
            view.textStorage.endEditing()
            view.selectedRange = selection
            context.coordinator.updatingFromModel = false
        }
        view.typingAttributes = typing

        if focused.wrappedValue && !view.isFirstResponder && view.window != nil {
            view.becomeFirstResponder()
        } else if !focused.wrappedValue && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 300, 1)
        let natural = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let maximum = ceil(line * 7)
        uiView.isScrollEnabled = natural > maximum
        return CGSize(width: width, height: min(max(natural, line), maximum))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var focused: FocusState<Bool>.Binding
        var mentionedRanges: @MainActor (String) -> [Range<String.Index>]
        var updatingFromModel = false

        init(
            text: Binding<String>, focused: FocusState<Bool>.Binding,
            mentionedRanges: @escaping @MainActor (String) -> [Range<String.Index>]
        ) {
            self.text = text
            self.focused = focused
            self.mentionedRanges = mentionedRanges
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            focused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            focused.wrappedValue = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !updatingFromModel else { return }
            let current = textView.text ?? ""
            if text.wrappedValue != current { text.wrappedValue = current }
        }
    }
}

/// Keeps the text a single colour and changes only the matched names' weight.
enum DraftMentionStyle {
    static func render(_ text: String, ranges: [Range<String.Index>], font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.label
        ])
        let bold = UIFont.systemFont(ofSize: font.pointSize, weight: .bold)
        for range in ranges {
            result.addAttribute(.font, value: bold, range: NSRange(range, in: text))
        }
        return result
    }
}

/// Map UIKit's UTF-16 selection through an external edit, such as choosing an
/// agent or removing an entire mention after Backspace. Typed edits need no map.
enum DraftSelection {
    static func remap(_ selection: NSRange, from old: String, to new: String) -> NSRange {
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
        func position(_ value: Int) -> Int {
            if value < prefix { return value }
            if value >= oldEnd { return value + newEnd - oldEnd }
            return newEnd
        }
        let start = min(max(position(selection.location), 0), after.count)
        let end = min(max(position(NSMaxRange(selection)), start), after.count)
        return NSRange(location: start, length: end - start)
    }
}
