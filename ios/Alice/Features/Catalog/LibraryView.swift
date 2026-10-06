import SwiftUI

/// What your agents made and what your notes carry, in three parts: Artifacts (files, documents and
/// links from your chats), Images (the pictures among them) and Notes (photos, files and links in
/// your notes). The part last open is the one that opens next time.
struct LibraryView: View {
    enum Part: String, CaseIterable, Identifiable {
        case artifacts, images, notes
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .artifacts: "Artifacts"
            case .images: "Images"
            case .notes: "Notes"
            }
        }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @AppStorage("alice.library.part") private var part: Part = .artifacts

    var body: some View {
        Group {
            switch part {
            case .artifacts: ArtifactsScreen(title: "Library", mode: .artifacts)
            case .images: ArtifactsScreen(title: "Library", mode: .images)
            case .notes:
                NoteAttachmentsScreen(scope: .all, title: "Library")
                    .scrollContentBackground(.hidden)
                    .background(Palette.background(scheme))
                    .task { try? await store.refreshNotes() }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $part) {
                ForEach(Part.allCases) { part in
                    Text(part.title).tag(part)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Palette.background(scheme))
            .accessibilityIdentifier("library.part")
        }
    }
}
