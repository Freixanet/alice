import SwiftUI

/// What the agent has made or pointed at lately.
///
/// Hermes keeps no index of these. Its own gallery is built the same way this
/// one is — by reading recent sessions back and pulling the paths and links
/// out of what the agent said — so the list is a reading of the record, not a
/// query against a store, and it says as much at the bottom.
struct ArtifactsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var found: [Artifact] = []
    @State private var kind: Artifact.Kind = .file
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        Group {
            if loading && found.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading recent sessions…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(
                    "Artifacts", systemImage: "paperclip", description: Text(failure)
                )
            } else if found.isEmpty {
                ContentUnavailableView(
                    "Nothing found", systemImage: "paperclip",
                    description: Text("No files or links in the recent sessions.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task { await load() }
        .refreshable { await load() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) {
                ForEach(Artifact.Kind.allCases, id: \.self) { option in
                    Text("\(option.title) \(count(option))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            List {
                ForEach(rows) { artifact in
                    row(artifact)
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Read back from the fifteen most recent sessions. Hermes keeps no list of its own, so this finds what the agent mentioned — which can include something it only read.")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ artifact: Artifact) -> some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(artifact.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(artifact.value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Text(subtitle(artifact))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)

        Group {
            if artifact.kind == .link, let url = URL(string: artifact.value) {
                Button { openURL(url) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .listRowBackground(Palette.card(scheme))
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = artifact.value
            }
        }
    }

    private func subtitle(_ artifact: Artifact) -> String {
        var parts: [String] = []
        if let tool = artifact.tool { parts.append(tool) }
        parts.append(artifact.session)
        if let when = artifact.when {
            parts.append(when.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private var rows: [Artifact] { found.filter { $0.kind == kind } }

    private func count(_ option: Artifact.Kind) -> String {
        let total = found.filter { $0.kind == option }.count
        return total == 0 ? "" : "\(total)"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            found = try await store.artifacts()
            failure = nil
            // Land on whichever kind actually has something in it.
            if rows.isEmpty, let first = Artifact.Kind.allCases.first(where: { option in
                found.contains { $0.kind == option }
            }) {
                kind = first
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "Hermes did not answer."
        }
    }
}
