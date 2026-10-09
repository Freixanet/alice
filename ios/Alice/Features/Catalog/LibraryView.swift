import SwiftUI

/// What your agents made and what you wrote, in three parts: Artifacts (files, documents and links
/// from your chats), Images (the pictures among them) and Notes (your notes, by folder). The part last open is the one that opens next time.
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
                // The notes themselves, folders first, as they were in the drawer.
                NotesFoldersScreen(title: "Library", closes: false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $part) {
                ForEach(Part.allCases) { part in
                    Text(part.title).tag(part)
                }
            }
            .segments()
            .padding(.horizontal, 16)
            // As far from the back button as Settings' first section is.
            .padding(.top, 20)
            .padding(.bottom, 8)
            .background(Palette.background(scheme))
            .accessibilityIdentifier("library.part")
        }
    }
}
