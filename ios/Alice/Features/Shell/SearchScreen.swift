import SwiftUI

/// Search over the whole history, given the screen rather than a strip at the
/// top of the drawer.
///
/// A field in the drawer could only ever match titles, which are the one part
/// of a conversation nobody wrote on purpose. With room to show a matching
/// line, the same query can look inside the messages too.
///
/// The field sits at the bottom, where the thumb already is and where the
/// keyboard will not have to be reached over — `safeAreaInset` rides it up as
/// the keyboard arrives. Results grow upward from it, so a single match lands
/// beside the query rather than a screen away from it.
struct SearchScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    /// Opening a result should leave the drawer behind it closed too.
    let onOpen: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Palette.background(scheme).ignoresSafeArea()

            if query.isEmpty {
                // An empty field is not an empty screen: what you most likely
                // want is a conversation you had recently, and offering them
                // saves typing a query to find something you could point at.
                // A heading over nothing, though, is worse than the sentence.
                if recents.isEmpty {
                    hint("Search your conversations")
                } else {
                    list(
                        recents.map { Result(conversation: $0, line: nil) },
                        heading: "Recent"
                    )
                }
            } else if results.isEmpty {
                hint("Nothing matches “\(query)”")
            } else {
                list(results, heading: nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .task { focused = true }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ rows: [Result], heading: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let heading {
                    Text(heading)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                ForEach(rows, id: \.conversation.id) { result in
                    Button {
                        store.activeID = result.conversation.id
                        onOpen()
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.conversation.title)
                                .lineLimit(1)
                            if let line = result.line {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Palette.card(scheme), in: .rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        // Matches settle against the field rather than at the far end of an
        // otherwise empty screen.
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Most recently opened first — which is not the same as most recently
    /// written to: a conversation reread this morning belongs above one that
    /// was last replied to a week ago.
    private var recents: [Conversation] {
        store.conversations
            .filter { !$0.messages.isEmpty }
            .sorted { ($0.openedAt ?? $0.updatedAt) > ($1.openedAt ?? $1.updatedAt) }
            .prefix(12)
            .map { $0 }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Conversations and messages", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    // A search field is not a sentence: capitalising the first
                    // letter and second-guessing the rest only gets in the way
                    // of finding what was actually written.
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private struct Result {
        let conversation: Conversation
        /// The message the query was found in, if the title was not the match.
        let line: String?
    }

    private var results: [Result] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return store.conversations.compactMap { conversation in
            if conversation.title.localizedCaseInsensitiveContains(needle) {
                return Result(conversation: conversation, line: nil)
            }
            let hit = conversation.messages.first {
                $0.content.localizedCaseInsensitiveContains(needle)
            }
            guard let hit else { return nil }
            return Result(conversation: conversation, line: snippet(hit.content, around: needle))
        }
    }

    /// The matching words with a little either side, rather than the opening of
    /// a message that may not contain the query at all.
    private func snippet(_ text: String, around needle: String) -> String {
        guard let range = text.range(of: needle, options: .caseInsensitive) else {
            return text
        }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex)
            ?? text.endIndex
        var line = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start != text.startIndex { line = "…" + line }
        if end != text.endIndex { line += "…" }
        return line
    }
}
