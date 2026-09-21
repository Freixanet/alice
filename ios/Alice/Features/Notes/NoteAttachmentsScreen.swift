import SwiftUI
import UIKit

/// What the notes in a folder carry besides their words.
///
/// Files and photos the person attached sit first, newest note first; links
/// the store picked out of the text follow. An older plugin has no files, so
/// the page still lists the links.
struct NoteAttachmentsScreen: View {
    let scope: NotesScope

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    private var notes: [Note] {
        NotesFeed.ordered(store.notes(in: scope), by: .dateCreated)
            .filter { !store.isLocked($0) || store.lockedNotesOpen }
    }

    private var files: [(note: Note, attachment: Attachment)] {
        notes.flatMap { note in
            (note.attachments ?? []).map { (note, $0) }
        }
    }

    private var links: [(note: Note, url: URL)] {
        notes.flatMap { note in
            note.urls.compactMap { raw in
                URL(string: raw).map { (note, $0) }
            }
        }
    }

    var body: some View {
        List {
            if files.isEmpty && links.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Attachments",
                        systemImage: "paperclip",
                        description: Text("Photos, files and links in these notes show up here.")
                    )
                }
                .listRowBackground(Color.clear)
            }
            if !files.isEmpty {
                Section("Files") {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, item in
                        fileRow(item.attachment, note: item.note)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }
            if !links.isEmpty {
                Section("Links") {
                    ForEach(Array(links.enumerated()), id: \.offset) { _, item in
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
            }
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 36, for: .scrollContent)
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationTitle("Attachments")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fileRow(_ attachment: Attachment, note: Note) -> some View {
        HStack(spacing: 12) {
            if attachment.kind == .image, let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(store.accent.primary(scheme))
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(NotesFeed.title(of: note))
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
