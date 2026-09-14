import SwiftUI

/// What your agents made and shared lately, for someone who never needs to
/// know what a path is.
///
/// Hermes keeps no index of these. Its own gallery is built the same way this
/// one is — by reading recent sessions back and pulling out what the agent
/// produced — so the screen says plainly where the list comes from. Files are
/// only those an agent created or changed (`ArtifactScanner.creatingTools`);
/// links only those it handed over in its own words.
struct ArtifactsScreen: View {
    var title = "Artifacts"

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var found: [Artifact] = []
    @State private var kind: Shelf = .files
    @State private var failure: String?
    @State private var loading = false
    @State private var opened: RemoteFileSelection?

    /// Images are files too: one shelf for what was made, one for what was shared.
    enum Shelf: String, CaseIterable, Hashable {
        case files = "Files"
        case links = "Links"
    }

    var body: some View {
        Group {
            if loading && found.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking through your recent chats…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(
                    title, systemImage: "tray", description: Text(failure)
                )
            } else if found.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet", systemImage: "tray",
                    description: Text("When your agents create a file or share a link in a chat with Alice, it appears here.")
                )
            } else {
                list
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $opened) { selection in
            HermesRemoteFileDetail(selection: selection)
                .environment(store)
                .preferredColorScheme(store.theme.colorScheme)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $kind) {
                ForEach(Shelf.allCases, id: \.self) { shelf in
                    Text(label(shelf)).tag(shelf)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            List {
                Section {
                    EmptyView()
                } footer: {
                    Text(kind == .files
                         ? "Files your agents created or changed in your recent chats with Alice. They live on the computer running Hermes; tap one to see it."
                         : "Links your agents gave you in your recent chats with Alice. Tap one to open it.")
                }

                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { artifact in
                            row(artifact)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ artifact: Artifact) -> some View {
        Button {
            open(artifact)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(artifact))
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.kind == .link ? linkTitle(artifact) : artifact.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let when = artifact.when {
                        Text(when.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.card(scheme))
        .contextMenu {
            Button(artifact.kind == .link ? "Copy Link" : "Copy Location", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = artifact.value
            }
        }
    }

    private func open(_ artifact: Artifact) {
        switch artifact.kind {
        case .link:
            if let url = URL(string: artifact.value) { openURL(url) }
        case .file, .image:
            opened = RemoteFileSelection(
                source: .workspace, name: artifact.name, path: artifact.value, readOnly: true
            )
        }
    }

    private func symbol(_ artifact: Artifact) -> String {
        artifact.kind == .link ? "link" : RemoteFileSymbol.name(mime: nil, fileName: artifact.name)
    }

    /// A page's address without the scheme, which is what anybody reads.
    private func linkTitle(_ artifact: Artifact) -> String {
        guard let url = URL(string: artifact.value), let host = url.host else { return artifact.value }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path == "/" ? "" : url.path
        return site + path
    }

    private var shelfItems: [Artifact] {
        found.filter { kind == .links ? $0.kind == .link : $0.kind != .link }
    }

    /// Files by the chat they came from; links by the site they point to. The
    /// group with the newest item first.
    private var groups: [(title: String, items: [Artifact])] {
        let grouped = Dictionary(grouping: shelfItems) { artifact -> String in
            if artifact.kind == .link {
                let host = URL(string: artifact.value)?.host ?? artifact.value
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return artifact.session.isEmpty ? "Untitled chat" : artifact.session
        }
        return grouped
            .map { (title: $0.key, items: $0.value.sorted { ($0.when ?? .distantPast) > ($1.when ?? .distantPast) }) }
            .sorted { ($0.items.first?.when ?? .distantPast) > ($1.items.first?.when ?? .distantPast) }
    }

    private func label(_ shelf: Shelf) -> String {
        let total = found.filter { shelf == .links ? $0.kind == .link : $0.kind != .link }.count
        return total == 0 ? shelf.rawValue : "\(shelf.rawValue) \(total)"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            found = try await store.artifacts()
            failure = nil
            // Land on whichever shelf actually has something on it.
            if shelfItems.isEmpty, let other = Shelf.allCases.first(where: { shelf in
                found.contains { shelf == .links ? $0.kind == .link : $0.kind != .link }
            }) {
                kind = other
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "Hermes did not answer."
        }
    }
}
