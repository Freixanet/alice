import SwiftUI
import UIKit

/// One note, open to edit, on a page of its own.
///
/// Styled text the way Notes writes it: the system's formatting — styles,
/// fonts, sizes, colours, highlight, lists, alignment — under Format in the
/// text's menu, and the everyday ones in a bar above the keyboard. The styled
/// copy is kept as RTF beside the plain words, which stay what agents read.
/// Changes save as they are made, and once more on leaving.
struct NoteEditor: View {
    /// A note to edit, or a new one: the same page either way.
    enum Target: Hashable, Identifiable {
        case existing(Note)
        case new(UUID)

        var id: String {
            switch self {
            case let .existing(note): note.id
            case let .new(token): "new-\(token.uuidString)"
            }
        }
    }

    let agent: String?
    /// Where a new note is filed once it exists.
    var folder: NotesScope = .quick

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    /// The note once it exists in the store; nil for a new one not yet saved.
    @State private var note: Note?
    @State private var content: NSAttributedString
    @State private var saved: NSAttributedString
    @State private var saving: Task<Void, Never>?
    /// Creating the note is in flight: later saves wait for its id.
    @State private var creating: Task<Note?, Never>?
    @State private var failure: String?
    @State private var showingDetails = false
    /// The caret is in the note — or about to be, as the page opens with the
    /// keyboard up, so Done is there from the start rather than a beat later.
    @State private var editing = true

    init(target: Target, agent: String?, folder: NotesScope = .quick) {
        self.agent = agent
        self.folder = folder
        let initial: NSAttributedString
        switch target {
        case let .existing(existing):
            _note = State(initialValue: existing)
            initial = RichNote.attributed(from: existing)
        case .new:
            _note = State(initialValue: nil)
            initial = NSAttributedString()
        }
        _content = State(initialValue: initial)
        _saved = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No date on this page: the list says when a note was written.
            // The space keeps the text clear of the header, and a tap there
            // puts the keyboard away.
            Color.clear
                .frame(height: 28)
                .contentShape(.rect)
                .onTapGesture { dismissKeyboard() }
            // The keyboard is up on arrival: opening a note is to write in it.
            RichTextEditor(
                text: $content, isEditing: $editing, focusOnAppear: true,
                startsWithTitle: note == nil
            )
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Palette.background(scheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if note != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Details", systemImage: "info.circle") { showingDetails = true }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: content.string)
            }
            // Done writing: saved now, keyboard and caret put away.
            if editing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        save(now: true)
                        dismissKeyboard()
                    }
                    .accessibilityIdentifier("note.done")
                }
            }
            if note != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Delete Note", systemImage: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Note", role: .destructive) { deleteNote() }
        } message: {
            Text("It is removed from the notes store, with what its agent made of it. This can’t be undone.")
        }
        .onAppear { store.editingNote = true }
        .onChange(of: content) { scheduleSave() }
        .onDisappear {
            store.editingNote = false
            if !deleted { save(now: true) }
        }
        .sheet(isPresented: $showingDetails) {
            if let currentNote {
                NoteDetail(note: currentNote, agent: agent)
                    .environment(store)
                    .preferredColorScheme(store.theme.colorScheme)
            }
        }
        .alert(
            "Note not saved",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("Try Again") { save(now: true) }
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @State private var deleted = false

    private func deleteNote() {
        guard let existing = currentNote else { return }
        saving?.cancel()
        deleted = true
        dismiss()
        Task {
            do {
                try await store.deleteNote(existing)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not delete the note."
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    /// The note as the store has it now, with what the agent made of it.
    private var currentNote: Note? {
        guard let note else { return nil }
        return store.notesSnapshot?.notes.first { $0.id == note.id } ?? note
    }

    private func scheduleSave() {
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            save(now: false)
        }
    }

    private func save(now: Bool) {
        if now { saving?.cancel() }
        let edited = content
        let words = edited.string
        guard !edited.isEqual(to: saved),
              !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        saved = edited
        let rich = RichNote.rtf(from: edited)
        Task {
            do {
                if let existing = currentNote {
                    try await store.editNote(existing, text: words, rich: rich)
                } else if let pending = creating {
                    // Created a moment ago and not back yet: edit it once it is.
                    guard let created = await pending.value else { return }
                    try await store.editNote(created, text: words, rich: rich)
                } else {
                    let create = Task<Note?, Never> {
                        try? await store.addNote(words)
                    }
                    creating = create
                    guard let created = await create.value else {
                        creating = nil
                        throw HermesRPCClient.Failure(reason: "Hermes did not save the note.")
                    }
                    note = created
                    await store.put(created.id, in: folder)
                    creating = nil
                    // The styling goes in with the first edit, as adding takes words only.
                    if let rich, !content.string.isEmpty {
                        try await store.editNote(created, text: words, rich: rich)
                    }
                }
            } catch {
                saved = NSAttributedString()
                failure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not save the note."
            }
        }
    }
}

/// Moving a note between its stored forms.
enum RichNote {
    static let bodyFont = UIFont.preferredFont(forTextStyle: .body)

    /// The title a new note starts with: larger and heavier than the body.
    static var titleAttributes: [NSAttributedString.Key: Any] {
        let base = UIFont.preferredFont(forTextStyle: .title1)
        let bold = base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base
        return [.font: bold, .foregroundColor: UIColor.label]
    }

    /// The styled copy when there is one, else the plain words in the body style.
    static func attributed(from note: Note) -> NSAttributedString {
        if let rich = note.rich, let data = Data(base64Encoded: rich),
           let styled = try? NSMutableAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            adaptTextColor(styled)
            return styled
        }
        return NSAttributedString(
            string: note.text,
            attributes: [.font: bodyFont, .foregroundColor: UIColor.label]
        )
    }

    /// RTF, base64. Text left in the default colour is saved without one, so
    /// it reads in both light and dark rather than fixed as black.
    static func rtf(from text: NSAttributedString) -> String? {
        let copy = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if let color = value as? UIColor, color == UIColor.label {
                copy.removeAttribute(.foregroundColor, range: range)
            }
        }
        guard let data = try? copy.data(
            from: whole,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else { return nil }
        return data.base64EncodedString()
    }

    /// RTF has no "default" colour: uncoloured text comes back black. Black
    /// (and missing) goes back to the dynamic label colour.
    private static func adaptTextColor(_ text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let color = value as? UIColor else {
                text.addAttribute(.foregroundColor, value: UIColor.label, range: range)
                return
            }
            var white: CGFloat = 0, alpha: CGFloat = 0
            if color.getWhite(&white, alpha: &alpha), white < 0.01 {
                text.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
        }
    }
}

/// An input accessory with a height of its own, for the keyboard to lay out.
private final class AccessoryHost: UIView {
    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        autoresizingMask = .flexibleHeight
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height)
    }
}

/// A `UITextView` that edits styled text, with the system's Format menu and a
/// Notes-like bar above the keyboard.
private struct RichTextEditor: UIViewRepresentable {
    @Binding var text: NSAttributedString
    @Binding var isEditing: Bool
    var focusOnAppear = false
    /// A new note: its first line is written as a title.
    var startsWithTitle = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isEditing: $isEditing) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.allowsEditingTextAttributes = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 40, right: 16)
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        view.attributedText = text
        view.typingAttributes = startsWithTitle && text.length == 0
            ? RichNote.titleAttributes
            : [.font: RichNote.bodyFont, .foregroundColor: UIColor.label]
        context.coordinator.titleFirstLine = startsWithTitle
        view.delegate = context.coordinator
        view.inputAccessoryView = context.coordinator.formatBar(for: view)
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.tapped(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        if focusOnAppear {
            // Once the push has finished. Raised mid-push, the keyboard's own
            // animation fought the page's: the page paused halfway and the bar
            // above the keys drew dark before it settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                guard view.window != nil else { return }
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if !view.attributedText.isEqual(to: text) {
            let selection = view.selectedRange
            view.attributedText = text
            view.selectedRange = selection
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private let text: Binding<NSAttributedString>
        private let isEditing: Binding<Bool>
        private weak var view: UITextView?
        /// A new note, whose first line is its title.
        var titleFirstLine = false

        init(text: Binding<NSAttributedString>, isEditing: Binding<Bool>) {
            self.text = text
            self.isEditing = isEditing
        }

        func textViewDidBeginEditing(_ textView: UITextView) { isEditing.wrappedValue = true }
        func textViewDidEndEditing(_ textView: UITextView) { isEditing.wrappedValue = false }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.attributedText
            refreshStates()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshStates()
        }

        // MARK: - What the buttons show

        enum Format: Hashable { case bold, italic, underline, strikethrough, bulleted, numbered, checklist }

        private var formatButtons: [Format: UIButton] = [:]
        private let feedback = UISelectionFeedbackGenerator()

        /// Lights each button whose formatting applies at the caret, or at the
        /// start of the selection: the only way to see that a tap took effect
        /// before anything has been typed.
        func refreshStates() {
            guard let view else { return }
            let range = view.selectedRange
            let attributes: [NSAttributedString.Key: Any] =
                range.length > 0 && range.location < view.textStorage.length
                    ? view.textStorage.attributes(at: range.location, effectiveRange: nil)
                    : view.typingAttributes
            let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let string = view.textStorage.string as NSString
            let line = string.substring(with: string.paragraphRange(for: NSRange(location: range.location, length: 0)))
            let numbered: Bool = {
                guard let dot = line.firstIndex(of: "."), Int(line[..<dot]) != nil else { return false }
                return line[line.index(after: dot)...].hasPrefix(" ")
            }()
            let states: [Format: Bool] = [
                .bold: traits.contains(.traitBold),
                .italic: traits.contains(.traitItalic),
                .underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                .strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
                .bulleted: line.hasPrefix("• "),
                .numbered: numbered,
                .checklist: line.hasPrefix("☐ ") || line.hasPrefix("☑ "),
            ]
            for (key, on) in states where formatButtons[key]?.isSelected != on {
                formatButtons[key]?.isSelected = on
            }
        }

        // MARK: - The bar above the keyboard

        /// A floating glass bar with room around it, as Notes draws its own:
        /// the formatting buttons scroll sideways when the screen is narrow, and
        /// hiding the keyboard keeps its own place at the end. A plain toolbar
        /// squeezed eleven buttons edge to edge against the keys, and the last
        /// one to a sliver.
        func formatBar(for view: UITextView) -> UIView {
            self.view = view
            // Its own height, stated: a plain view sized by its frame was laid
            // out at no height at all, so its buttons were drawn but could not
            // be touched, and a re-layout after the style menu cut its ends off.
            let host = AccessoryHost(height: 64)

            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.translatesAutoresizingMaskIntoConstraints = false
            // The glass keeps its shape through its own corner configuration;
            // a layer radius is dropped when the effect redraws.
            glass.cornerConfiguration = .capsule()
            host.addSubview(glass)

            func button(
                _ symbol: String, _ label: String, key: Format? = nil, _ run: (() -> Void)?
            ) -> UIButton {
                var configuration = UIButton.Configuration.plain()
                configuration.image = UIImage(
                    systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
                )
                configuration.baseForegroundColor = .label
                configuration.contentInsets = .zero
                let control = UIButton(configuration: configuration)
                if let run {
                    control.addAction(UIAction { [weak self] _ in
                        run()
                        self?.feedback.selectionChanged()
                        self?.refreshStates()
                    }, for: .touchUpInside)
                }
                if let key {
                    // On while that formatting applies where the caret is.
                    control.configurationUpdateHandler = { button in
                        var updated = button.configuration
                        let on = button.isSelected
                        updated?.baseForegroundColor = on ? .tintColor : .label
                        updated?.background.backgroundColor = on
                            ? UIColor.tintColor.withAlphaComponent(0.16) : .clear
                        // A circle, as the buttons are square.
                        updated?.background.cornerRadius = 22
                        button.configuration = updated
                    }
                    formatButtons[key] = control
                }
                control.accessibilityLabel = label
                control.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    control.widthAnchor.constraint(equalToConstant: 44),
                    control.heightAnchor.constraint(equalToConstant: 44),
                ])
                return control
            }

            let styles = button("textformat", "Text Style", nil)
            styles.menu = styleMenu()
            styles.showsMenuAsPrimaryAction = true
            let row = UIStackView(arrangedSubviews: [
                styles,
                button("bold", "Bold", key: .bold) { [weak self] in self?.bold() },
                button("italic", "Italic", key: .italic) { [weak self] in self?.italic() },
                button("underline", "Underline", key: .underline) { [weak self] in self?.underline() },
                button("strikethrough", "Strikethrough", key: .strikethrough) { [weak self] in self?.strikethrough() },
                button("list.bullet", "Bulleted List", key: .bulleted) { [weak self] in self?.bulleted() },
                button("list.number", "Numbered List", key: .numbered) { [weak self] in self?.numbered() },
                button("checklist", "Checklist", key: .checklist) { [weak self] in self?.checklist() },
            ])
            row.axis = .horizontal
            row.spacing = 2
            row.translatesAutoresizingMaskIntoConstraints = false

            let scroller = UIScrollView()
            scroller.showsHorizontalScrollIndicator = false
            scroller.alwaysBounceHorizontal = false
            scroller.translatesAutoresizingMaskIntoConstraints = false
            scroller.addSubview(row)

            glass.contentView.addSubview(scroller)

            // Flicked down, the bar takes the keyboard with it, as the composer does.
            let pull = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
            pull.cancelsTouchesInView = false
            pull.delegate = self
            host.addGestureRecognizer(pull)

            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                glass.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
                glass.topAnchor.constraint(equalTo: host.topAnchor, constant: 6),
                glass.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),

                scroller.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
                scroller.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
                scroller.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
                scroller.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),

                row.leadingAnchor.constraint(equalTo: scroller.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: scroller.trailingAnchor),
                row.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 44),
                // Spread out when there is room, scrolling only when there is not.
                row.widthAnchor.constraint(greaterThanOrEqualTo: scroller.widthAnchor),
            ])
            row.distribution = .equalSpacing
            return host
        }

        private func styleMenu() -> UIMenu {
            let styles: [(String, UIFont.TextStyle, Bool)] = [
                ("Title", .largeTitle, true), ("Heading", .title2, true),
                ("Subheading", .headline, false), ("Body", .body, false),
            ]
            var actions = styles.map { name, style, bold in
                UIAction(title: name) { [weak self] _ in
                    var font = UIFont.preferredFont(forTextStyle: style)
                    if bold, let heavy = font.fontDescriptor.withSymbolicTraits(.traitBold) {
                        font = UIFont(descriptor: heavy, size: 0)
                    }
                    self?.setParagraphFont(font)
                }
            }
            actions.append(UIAction(title: "Monospaced") { [weak self] _ in
                self?.setParagraphFont(.monospacedSystemFont(
                    ofSize: RichNote.bodyFont.pointSize, weight: .regular
                ))
            })
            return UIMenu(title: "Text Style", children: actions)
        }

        @objc private func bold() { view?.toggleBoldface(nil); changed() }
        @objc private func italic() { view?.toggleItalics(nil); changed() }
        @objc private func underline() { view?.toggleUnderline(nil); changed() }
        @objc private func pulled(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended || recognizer.state == .changed,
                  let host = recognizer.view else { return }
            let moved = recognizer.translation(in: host)
            if moved.y > 24, moved.y > abs(moved.x) { view?.resignFirstResponder() }
        }

        @objc private func strikethrough() {
            guard let view else { return }
            let range = view.selectedRange
            if range.length == 0 {
                var typing = view.typingAttributes
                let on = (typing[.strikethroughStyle] as? Int ?? 0) != 0
                typing[.strikethroughStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
                view.typingAttributes = typing
                return
            }
            let on = (view.textStorage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
            if on {
                view.textStorage.removeAttribute(.strikethroughStyle, range: range)
            } else {
                view.textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            changed()
        }

        @objc private func bulleted() { toggleMarker { _ in "• " } }
        @objc private func numbered() { toggleMarker { "\($0 + 1). " } }
        @objc private func checklist() { toggleMarker { _ in "☐ " } }

        /// The paragraphs the selection touches.
        private func paragraphRanges(in view: UITextView) -> [NSRange] {
            let string = view.textStorage.string as NSString
            let covered = string.paragraphRange(for: view.selectedRange)
            var ranges: [NSRange] = []
            string.enumerateSubstrings(in: covered, options: .byParagraphs) { _, range, _, _ in
                ranges.append(range)
            }
            if ranges.isEmpty { ranges = [NSRange(location: covered.location, length: 0)] }
            return ranges
        }

        private func setParagraphFont(_ font: UIFont) {
            guard let view else { return }
            for range in paragraphRanges(in: view) where range.length > 0 {
                view.textStorage.addAttribute(.font, value: font, range: range)
            }
            view.typingAttributes[.font] = font
            changed()
        }

        /// Adds a list marker to each selected paragraph, or takes it away when
        /// every one already starts with it. A checked box counts as a box.
        private func toggleMarker(_ marker: (Int) -> String) {
            guard let view else { return }
            let storage = view.textStorage
            let ranges = paragraphRanges(in: view)
            let string = storage.string as NSString
            func existing(at range: NSRange, index: Int) -> NSRange? {
                let line = string.substring(with: range)
                for candidate in [marker(index), "☑ "] where line.hasPrefix(candidate) {
                    return NSRange(location: range.location, length: (candidate as NSString).length)
                }
                return nil
            }
            let removing = ranges.enumerated().allSatisfy { existing(at: $1, index: $0) != nil }
            let selection = view.selectedRange
            var shift = 0
            storage.beginEditing()
            for (index, range) in ranges.enumerated() {
                let at = NSRange(location: range.location + shift, length: range.length)
                if removing, let found = existing(at: range, index: index) {
                    storage.deleteCharacters(in: NSRange(location: found.location + shift, length: found.length))
                    shift -= found.length
                } else if !removing {
                    let text = marker(index)
                    var attributes = view.typingAttributes
                    if at.location < storage.length {
                        attributes = storage.attributes(at: at.location, effectiveRange: nil)
                    }
                    storage.insert(NSAttributedString(string: text, attributes: attributes), at: at.location)
                    shift += (text as NSString).length
                }
            }
            storage.endEditing()
            view.selectedRange = NSRange(location: max(0, selection.location + (removing ? min(0, shift) : (marker(0) as NSString).length)), length: 0)
            changed()
        }

        // MARK: - Lists

        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String
        ) -> Bool {
            // A new note's first line is its title; the line after it is
            // ordinary text, as in Notes.
            if titleFirstLine, replacement == "\n",
               (textView.textStorage.string as NSString)
                .substring(to: range.location).rangeOfCharacter(from: .newlines) == nil {
                let body: [NSAttributedString.Key: Any] = [.font: RichNote.bodyFont, .foregroundColor: UIColor.label]
                textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: body))
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                textView.typingAttributes = body
                changed()
                return false
            }
            // Emptied again, it starts again with the title.
            if titleFirstLine, replacement.isEmpty, range.location == 0,
               range.length == textView.textStorage.length {
                DispatchQueue.main.async { textView.typingAttributes = RichNote.titleAttributes }
            }
            // A new line inside a list carries its marker on, as in Notes; an
            // empty item ends the list.
            guard replacement == "\n" else { return true }
            let string = textView.textStorage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            let line = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let markers = ["• ", "☐ ", "☑ "]
            var next: String?
            if let marker = markers.first(where: { line.hasPrefix($0) }) {
                if line == marker {
                    textView.textStorage.deleteCharacters(in: NSRange(location: paragraph.location, length: (marker as NSString).length))
                    textView.selectedRange = NSRange(location: paragraph.location, length: 0)
                    changed()
                    return false
                }
                next = marker == "☑ " ? "☐ " : marker
            } else if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                if line == "\(number). " {
                    textView.textStorage.deleteCharacters(in: NSRange(location: paragraph.location, length: ("\(number). " as NSString).length))
                    changed()
                    return false
                }
                next = "\(number + 1). "
            }
            guard let next else { return true }
            textView.textStorage.replaceCharacters(
                in: range,
                with: NSAttributedString(string: "\n" + next, attributes: textView.typingAttributes)
            )
            textView.selectedRange = NSRange(location: range.location + ("\n" + next as NSString).length, length: 0)
            changed()
            return false
        }

        /// A tap on a checklist box ticks or unticks it, without moving the caret.
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view, recognizer.state == .ended else { return }
            let point = recognizer.location(in: view)
            // A tap on the page below the writing puts the keyboard away.
            // Only if the keyboard was already up when the finger came down: a
            // first tap below a short note is how writing starts, and the text
            // view has taken focus by the time this runs.
            if editingAtTouch, let layout = view.textLayoutManager {
                let used = layout.usageBoundsForTextContainer
                let textBottom = used.maxY + view.textContainerInset.top
                if point.y > textBottom + 12 {
                    view.resignFirstResponder()
                    return
                }
            }
            guard let position = view.closestPosition(to: point),
                  let hit = view.characterRange(at: point) ?? view.textRange(from: position, to: position)
            else { return }
            let index = view.offset(from: view.beginningOfDocument, to: hit.start)
            let string = view.textStorage.string as NSString
            guard index >= 0, index < string.length else { return }
            let box = string.substring(with: NSRange(location: index, length: 1))
            guard box == "☐" || box == "☑" else { return }
            let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
            guard paragraph.location == index else { return }
            let attributes = view.textStorage.attributes(at: index, effectiveRange: nil)
            view.textStorage.replaceCharacters(
                in: NSRange(location: index, length: 1),
                with: NSAttributedString(string: box == "☐" ? "☑" : "☐", attributes: attributes)
            )
            changed()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        private var editingAtTouch = false

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer {
                editingAtTouch = view?.isFirstResponder == true
            }
            return true
        }

        private func changed() {
            guard let view else { return }
            text.wrappedValue = view.attributedText
        }
    }
}
