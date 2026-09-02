import SwiftUI

/// Search over the whole history, given the screen rather than a strip at the
/// top of the drawer.
///
/// A field in the drawer could only ever match titles, which are the one part
/// of a conversation nobody wrote on purpose. With room to show a matching
/// line, the same query can look inside the messages too.
struct SearchScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    /// Opening a result should leave the drawer behind it closed too.
    let onOpen: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    hint("Search your conversations")
                } else if results.isEmpty {
                    hint("Nothing matches “\(query)”")
                } else {
                    list
                }
            }
            .background(Palette.background(scheme))
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Conversations and messages"
            )
            // A search field is not a sentence: capitalising the first letter
            // and second-guessing the rest only gets in the way of finding
            // what was actually written.
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        List(results, id: \.conversation.id) { result in
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
            }
            .buttonStyle(.plain)
            .listRowBackground(Palette.card(scheme))
        }
        .scrollContentBackground(.hidden)
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
