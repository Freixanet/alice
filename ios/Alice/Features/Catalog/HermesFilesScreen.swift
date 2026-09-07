import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The Files surface of the connected Hermes installation.
///
/// This is deliberately separate from Alice's Library: Library is made from
/// chat artifacts; Files is the server-side managed tree and follows Hermes'
/// own root, size and sensitive-file rules.
struct HermesFilesScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var listing: ManagedFilesListing?
    @State private var loading = false
    @State private var failure: String?
    @State private var importing = false
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var pendingDelete: ManagedRemoteFile?
    @State private var selectedFile: ManagedRemoteFile?
    @State private var busy = false

    var body: some View {
        List {
            Section {
                if let listing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayPath(listing.path))
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        if let locked = listing.lockedRoot, !locked.isEmpty {
                            Text("Managed root: \(locked)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }

            Section("Files") {
                if loading && listing == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading files…").foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                } else if let failure, listing == nil {
                    stateRow("Files unavailable", detail: failure, systemImage: "folder.badge.questionmark")
                } else if let listing {
                    if let parent = listing.parent {
                        Button { Task { await load(parent) } } label: {
                            Label("Parent folder", systemImage: "arrow.up.left")
                        }
                        .listRowBackground(Palette.card(scheme))
                    }

                    if listing.entries.isEmpty {
                        stateRow(
                            "This folder is empty",
                            detail: "Upload a file or create a folder here.",
                            systemImage: "folder"
                        )
                    } else {
                        ForEach(listing.entries) { entry in
                            Button {
                                if entry.isDirectory {
                                    Task { await load(entry.path) }
                                } else {
                                    selectedFile = entry
                                }
                            } label: {
                                fileRow(entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = entry } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                }
            }

            if let failure, listing != nil {
                Section {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
        .navigationTitle("Hermes Files")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { creatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                    .disabled(listing == nil || busy)
                    .accessibilityLabel("New folder")
                Button { importing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(listing == nil || busy)
                    .accessibilityLabel("Upload file")
            }
        }
        .task { if listing == nil { await load(nil) } }
        .refreshable { await load(listing?.path) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            Task { await upload(url) }
        }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Create") { Task { await createFolder() } }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create it inside the current Hermes folder.")
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.name)?" } ?? "Delete file?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { Task { await delete(entry) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if pendingDelete?.isDirectory == true {
                Text("The folder and everything inside it will be deleted.")
            }
        }
        .sheet(item: $selectedFile) { entry in
            HermesFilePreview(entry: entry)
                .preferredColorScheme(store.theme.colorScheme)
        }
    }

    @ViewBuilder
    private func fileRow(_ entry: ManagedRemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : symbol(for: entry))
                .foregroundStyle(entry.isDirectory ? .secondary : .primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).lineLimit(1)
                HStack(spacing: 5) {
                    if !entry.isDirectory, let size = entry.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let modified = entry.modified {
                        if !entry.isDirectory, entry.size != nil { Text("·") }
                        Text(modified.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: entry.isDirectory ? "chevron.right" : "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }

    private func stateRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Palette.card(scheme))
    }

    private func load(_ path: String?) async {
        loading = true
        defer { loading = false }
        do {
            listing = try await store.hermesFiles(path: path)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func upload(_ url: URL) async {
        guard let listing else { return }
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            try await store.uploadHermesFile(
                path: RemoteFilePath.join(listing.path, url.lastPathComponent),
                data: data, mimeType: mime
            )
            await load(listing.path)
        } catch {
            failure = reason(error)
        }
    }

    private func createFolder() async {
        guard let listing else { return }
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        folderName = ""
        guard !name.isEmpty else { return }
        guard RemoteFilePath.isSafeComponent(name) else {
            failure = "Folder names cannot be . or .. and cannot contain / or a null character."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await store.createHermesDirectory(path: RemoteFilePath.join(listing.path, name))
            await load(listing.path)
        } catch {
            failure = reason(error)
        }
    }

    private func delete(_ entry: ManagedRemoteFile) async {
        pendingDelete = nil
        guard let listing else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.deleteHermesFile(path: entry.path, recursive: entry.isDirectory)
            await load(listing.path)
        } catch {
            failure = reason(error)
        }
    }

    private func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Hermes did not answer."
    }

    private func displayPath(_ path: String) -> String { path.isEmpty ? "/" : path }

    private func symbol(for entry: ManagedRemoteFile) -> String {
        let mime = entry.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") { return "doc.text" }
        return "doc"
    }
}

/// Unix-style path joining without normalising away a server-provided root.
enum RemoteFilePath {
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func join(_ directory: String, _ name: String) -> String {
        let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !directory.isEmpty else { return cleanName }
        if directory == "/" { return "/" + cleanName }
        return directory.hasSuffix("/") ? directory + cleanName : directory + "/" + cleanName
    }
}

private struct HermesFilePreview: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let entry: ManagedRemoteFile
    @State private var contents: ManagedFileContents?
    @State private var localURL: URL?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if loading && contents == nil {
                    ProgressView("Loading file…")
                } else if let failure {
                    ContentUnavailableView("Couldn’t open file", systemImage: "doc.badge.ellipsis", description: Text(failure))
                } else if let contents {
                    preview(contents)
                } else {
                    ContentUnavailableView("No preview", systemImage: "doc")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background(scheme))
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let localURL {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: localURL) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func preview(_ file: ManagedFileContents) -> some View {
        if file.mimeType.lowercased().hasPrefix("image/"), let image = UIImage(data: file.data) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit().padding()
            }
        } else if isText(file.mimeType), let text = String(data: file.data, encoding: .utf8) {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            ContentUnavailableView {
                Label("Preview not available", systemImage: "doc")
            } description: {
                Text("\(file.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
            } actions: {
                if let localURL { ShareLink("Open or share", item: localURL) }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let file = try await store.hermesFile(path: entry.path)
            contents = file
            let safeName = URL(fileURLWithPath: file.name).lastPathComponent
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "alice-hermes-files", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: safeName)
            try file.data.write(to: url, options: .atomic)
            localURL = url
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "Hermes did not answer."
        }
    }

    private func isText(_ mime: String) -> Bool {
        let mime = mime.lowercased()
        return mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml")
            || mime.contains("javascript") || mime.contains("yaml") || mime.contains("toml")
    }
}
