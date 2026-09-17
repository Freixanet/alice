import SwiftUI

/// What the notes in a folder carry besides their words.
///
/// A note here is text an agent keeps in a store — there are no photos or
/// scans to show — so what a note attaches is the links in it, which the store
/// picks out as it saves. They are listed newest first under the note they
/// came from, and open where any other link would.
struct NoteAttachmentsScreen: View {
    let scope: NotesScope

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    /// Every link in these notes, with the note it belongs to, newest first.
    private var attachments: [(note: Note, url: URL)] {
        NotesFeed.ordered(store.notes(in: scope), by: .dateCreated)
            .filter { !store.isLocked($0) || store.lockedNotesOpen }
            .flatMap { note in
                note.urls.compactMap { raw in
                    URL(string: raw).map { (note, $0) }
                }
            }
    }

    var body: some View {
        List {
            if attachments.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Attachments",
                        systemImage: "paperclip",
                        description: Text("Links in these notes show up here.")
                    )
                }
                .listRowBackground(Color.clear)
            }
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, item in
                Link(destination: item.url) {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(store.accent.primary(scheme))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.host() ?? item.url.absoluteString)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(NotesFeed.title(of: item.note))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
            }
            .listRowBackground(Palette.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 36, for: .scrollContent)
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationTitle("Attachments")
        .navigationBarTitleDisplayMode(.inline)
    }
}
