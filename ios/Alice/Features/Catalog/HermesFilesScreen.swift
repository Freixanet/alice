import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum HermesFilesMode: String, CaseIterable, Identifiable {
    case managed = "Managed"
    case workspace = "Workspace"
    var id: String { rawValue }
}

enum RemoteFileSource: String, Hashable {
    case managed
    case workspace
}

struct RemoteFileSelection: Identifiable, Hashable {
    var id: String { source.rawValue + "|" + path }
    var source: RemoteFileSource
    var name: String
    var path: String
    var size: Int64?
    var mimeType: String?
    /// Shown, never edited: Library opens what an agent made, and a report
    /// changed by an accidental tap is no longer the agent's report.
    var readOnly = false
}

/// A remote file's failure, said the way a person would say it.
///
/// Hermes' own answers are for a developer — "The dashboard returned 403:
/// Access to sensitive files is not allowed" — and the three a reader actually
/// meets have a plain meaning each.
enum RemoteFileProblem {
    static func describe(_ error: Error) -> String {
        if case let DashboardClient.Failure.http(status, _) = error {
            switch status {
            case 403: return "This file is private, so Alice doesn’t open it."
            case 404: return "This file isn’t there any more. It may have been moved or deleted."
            case 413: return "This file is too big to show here. You can still download it."
            default: break
            }
        }
        return PlainWords.describe(error)
    }
}

/// The symbol for a file, by its type.
enum RemoteFileSymbol {
    static func name(mime: String?, fileName: String) -> String {
        let value = mime?.lowercased() ?? ""
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if value.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "svg"].contains(ext) { return "photo" }
        if value.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "ogg", "opus"].contains(ext) { return "waveform" }
        if value.hasPrefix("video/") || ["mp4", "mov", "mkv", "webm", "avi"].contains(ext) { return "film" }
        if value == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if ["xlsx", "xls", "csv"].contains(ext) { return "tablecells" }
        if value.hasPrefix("text/") || value.contains("json") || value.contains("xml")
            || ["md", "txt", "swift", "py", "js", "ts", "tsx", "json", "yaml", "yml", "toml", "sh", "docx"].contains(ext) {
            return "doc.text"
        }
        return "doc"
    }
}

/// Hermes file administration has two deliberately different surfaces:
/// Managed follows the server's root + sensitive-file policy; Workspace mirrors
/// Hermes Desktop's authenticated remote filesystem for development work.
struct HermesFilesScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var mode: HermesFilesMode = .managed
    @State private var searchText = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var busyLabel: String?

    @State private var managedListing: ManagedFilesListing?
    @State private var managedLoading = false
    @State private var managedPathDraft = ""
    @State private var importing = false
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var pendingDelete: ManagedRemoteFile?

    @State private var workspaceListing: HermesFSDirectoryListing?
    @State private var workspaceLoading = false
    @State private var workspacePath = ""
    @State private var workspacePathDraft = ""
    @State private var defaultLocation: HermesFSDefaultLocation?
    @State private var gitRoot: String?
    @State private var creatingTextFile = false
    @State private var textFileName = ""

    @State private var selectedFile: RemoteFileSelection?

    var body: some View {
        List {
            Section {
                Picker("Files surface", selection: $mode) {
                    ForEach(HermesFilesMode.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Palette.card(scheme))
            }

            if mode == .managed {
                managedLocationSection
                managedFilesSection
            } else {
                workspaceLocationSection
                workspaceFilesSection
            }

            if let busyLabel {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(busyLabel).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            }

            if let failure {
                Section("Last error") {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .listRowBackground(Palette.card(scheme))
                }
            }
        }
        .navigationTitle("Hermes Files")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .searchable(text: $searchText, prompt: "Filter this folder")
        .toolbar { toolbarContent }
        .task {
            if managedListing == nil { await loadManaged(nil) }
        }
        .onChange(of: mode) { _, next in
            searchText = ""
            if next == .workspace, workspaceListing == nil {
                Task { await loadWorkspaceInitial() }
            }
        }
        .refreshableWithFeedback {
            if mode == .managed { await loadManaged(managedListing?.path) }
            else { await loadWorkspace(workspacePath) }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            Task { await upload(urls) }
        }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Create") { Task { await createManagedFolder() } }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create it inside the current managed folder.")
        }
        .alert("New text file", isPresented: $creatingTextFile) {
            TextField("Filename", text: $textFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { textFileName = "" }
            Button("Create") { Task { await createWorkspaceTextFile() } }
                .disabled(textFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Creates an empty UTF-8 file in the current workspace folder.")
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.name)?" } ?? "Delete path?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { Task { await deleteManaged(entry) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if pendingDelete?.isDirectory == true {
                Text("The folder and everything inside it will be deleted permanently on Hermes.")
            } else {
                Text("This permanently deletes the file on Hermes.")
            }
        }
        .sheet(item: $selectedFile) { selection in
            HermesRemoteFileDetail(selection: selection)
                .environment(store)
                .preferredColorScheme(store.theme.colorScheme)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if mode == .managed {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { creatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                    .disabled(managedListing == nil || busy)
                    .accessibilityLabel("New managed folder")
                Button { importing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(managedListing == nil || busy)
                    .accessibilityLabel("Upload files")
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { creatingTextFile = true } label: { Image(systemName: "doc.badge.plus") }
                    .disabled(workspacePath.isEmpty || busy)
                    .accessibilityLabel("New text file")
                Button { Task { await loadWorkspace(workspacePath) } } label: {
                    if workspaceLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(workspacePath.isEmpty || workspaceLoading)
                .accessibilityLabel("Refresh workspace")
            }
        }
    }

    private var managedLocationSection: some View {
        Section("Managed location") {
            if let listing = managedListing {
                VStack(alignment: .leading, spacing: 5) {
                    Text(listing.path)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    if let locked = listing.lockedRoot, !locked.isEmpty {
                        Text("Locked root: \(locked)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Hermes applies its managed-file sensitive-path policy here.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                if listing.canChangePath {
                    HStack(spacing: 8) {
                        TextField("Absolute path", text: $managedPathDraft)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await goManagedPath() } }
                        Button("Go") { Task { await goManagedPath() } }
                            .disabled(managedPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } else if managedLoading {
                ProgressView("Loading managed files…")
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var managedFilesSection: some View {
        Section("Files") {
            if let listing = managedListing {
                if let parent = listing.parent {
                    Button { Task { await loadManaged(parent) } } label: {
                        Label("Parent folder", systemImage: "arrow.up.left")
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                let entries = filteredManagedEntries(listing.entries)
                if entries.isEmpty {
                    stateRow(
                        searchText.isEmpty ? "This folder is empty" : "No matches",
                        detail: searchText.isEmpty ? "Upload a file or create a folder here." : "Nothing in this folder matches your filter.",
                        systemImage: "folder"
                    )
                } else {
                    ForEach(entries) { entry in
                        Button {
                            if entry.isDirectory {
                                Task { await loadManaged(entry.path) }
                            } else {
                                selectedFile = .init(
                                    source: .managed, name: entry.name, path: entry.path,
                                    size: entry.size.map(Int64.init), mimeType: entry.mimeType
                                )
                            }
                        } label: {
                            managedRow(entry)
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
            } else if managedLoading {
                ProgressView("Loading…").listRowBackground(Palette.card(scheme))
            } else {
                stateRow("Managed files unavailable", detail: failure ?? "Hermes did not answer.", systemImage: "folder.badge.questionmark")
            }
        }
    }

    private var workspaceLocationSection: some View {
        Section("Remote workspace") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Absolute path on Hermes", text: $workspacePathDraft)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await goWorkspacePath() } }
                    Button("Go") { Task { await goWorkspacePath() } }
                        .disabled(workspacePathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let location = defaultLocation {
                    Text("Hermes cwd: \(location.cwd)\(location.branch.isEmpty ? "" : " · \(location.branch)")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Workspace mirrors Hermes Desktop's development filesystem. It is broader than Managed Files and is intended for files you explicitly choose to inspect or edit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Palette.card(scheme))

            if let gitRoot {
                NavigationLink {
                    GitDevelopmentScreen(initialRepoPath: gitRoot)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Open repository in Git", systemImage: "arrow.triangle.branch")
                        Text(gitRoot).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var workspaceFilesSection: some View {
        Section("Workspace files") {
            if workspaceLoading && workspaceListing == nil {
                ProgressView("Loading workspace…")
                    .listRowBackground(Palette.card(scheme))
            } else if !workspacePath.isEmpty {
                if let parent = DashboardClient.advancedParentPath(workspacePath), parent != workspacePath {
                    Button { Task { await loadWorkspace(parent) } } label: {
                        Label("Parent folder", systemImage: "arrow.up.left")
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if let listing = workspaceListing {
                    if let error = listing.error {
                        stateRow("Couldn’t read this directory", detail: filesystemError(error), systemImage: "folder.badge.questionmark")
                    }
                    let entries = filteredWorkspaceEntries(listing.entries)
                    if entries.isEmpty && listing.error == nil {
                        stateRow(
                            searchText.isEmpty ? "This folder is empty" : "No matches",
                            detail: searchText.isEmpty ? "No visible entries. Hermes hides heavy generated directories such as .git, node_modules and build." : "Nothing in this folder matches your filter.",
                            systemImage: "folder"
                        )
                    } else {
                        ForEach(entries) { entry in
                            Button {
                                if entry.isDirectory {
                                    Task { await loadWorkspace(entry.path) }
                                } else {
                                    selectedFile = .init(
                                        source: .workspace, name: entry.name, path: entry.path,
                                        size: nil, mimeType: nil
                                    )
                                }
                            } label: {
                                workspaceRow(entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                }
            }
        }
    }

    private func managedRow(_ entry: ManagedRemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : symbol(mime: entry.mimeType, name: entry.name))
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
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }

    private func workspaceRow(_ entry: HermesFSDirectoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : symbol(mime: nil, name: entry.name))
                .foregroundStyle(entry.isDirectory ? .secondary : .primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(entry.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
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

    private func loadManaged(_ path: String?) async {
        managedLoading = true
        defer { managedLoading = false }
        do {
            let value = try await store.hermesFiles(path: path)
            managedListing = value
            managedPathDraft = value.path
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func goManagedPath() async {
        let path = managedPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        await loadManaged(path)
    }

    private func upload(_ urls: [URL]) async {
        guard let listing = managedListing, !urls.isEmpty else { return }
        busy = true
        defer {
            busy = false
            busyLabel = nil
        }
        for (index, url) in urls.enumerated() {
            busyLabel = urls.count == 1 ? "Uploading \(url.lastPathComponent)…" : "Uploading \(index + 1) of \(urls.count)…"
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                try await store.uploadHermesFileStream(
                    path: RemoteFilePath.join(listing.path, url.lastPathComponent),
                    fileURL: url, mimeType: mime, overwrite: true
                )
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                failure = reason(error)
                return
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        await loadManaged(listing.path)
    }

    private func createManagedFolder() async {
        guard let listing = managedListing else { return }
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        folderName = ""
        guard RemoteFilePath.isSafeComponent(name) else {
            failure = "Folder names cannot be . or .. and cannot contain / or a null character."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await store.createHermesDirectory(path: RemoteFilePath.join(listing.path, name))
            await loadManaged(listing.path)
        } catch {
            failure = reason(error)
        }
    }

    private func deleteManaged(_ entry: ManagedRemoteFile) async {
        pendingDelete = nil
        guard let listing = managedListing else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.deleteHermesFile(path: entry.path, recursive: entry.isDirectory)
            await loadManaged(listing.path)
        } catch {
            failure = reason(error)
        }
    }

    private func loadWorkspaceInitial() async {
        workspaceLoading = true
        defer { workspaceLoading = false }
        do {
            let location = try await store.hermesFilesystemDefaultLocation()
            defaultLocation = location
            let target = location.cwd == "/" && location.branch.isEmpty
                ? (managedListing?.path ?? location.cwd)
                : location.cwd
            workspacePath = target
            workspacePathDraft = target
            workspaceListing = try await store.hermesFilesystemDirectory(path: target)
            gitRoot = try? await store.hermesFilesystemGitRoot(path: target)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func loadWorkspace(_ path: String) async {
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        workspaceLoading = true
        defer { workspaceLoading = false }
        do {
            let listing = try await store.hermesFilesystemDirectory(path: target)
            workspacePath = target
            workspacePathDraft = target
            workspaceListing = listing
            gitRoot = try? await store.hermesFilesystemGitRoot(path: target)
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func goWorkspacePath() async {
        await loadWorkspace(workspacePathDraft)
    }

    private func createWorkspaceTextFile() async {
        let name = textFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        textFileName = ""
        guard RemoteFilePath.isSafeComponent(name) else {
            failure = "Filename cannot be . or .. and cannot contain / or a null character."
            return
        }
        guard !workspacePath.isEmpty else { return }
        let path = RemoteFilePath.join(workspacePath, name)
        busy = true
        defer { busy = false }
        do {
            _ = try await store.writeHermesFilesystemText(path: path, content: "")
            await loadWorkspace(workspacePath)
            selectedFile = .init(source: .workspace, name: name, path: path, size: 0, mimeType: "text/plain")
        } catch {
            failure = reason(error)
        }
    }

    private func filteredManagedEntries(_ entries: [ManagedRemoteFile]) -> [ManagedRemoteFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func filteredWorkspaceEntries(_ entries: [HermesFSDirectoryEntry]) -> [HermesFSDirectoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func filesystemError(_ code: String) -> String {
        switch code {
        case "ENOENT": "Path does not exist."
        case "ENOTDIR": "Path is not a directory."
        case "EACCES": "Hermes does not have permission to read this directory."
        default: code
        }
    }

    private func reason(_ error: Error) -> String {
        PlainWords.describe(error)
    }

    private func symbol(mime: String?, name: String) -> String {
        let value = mime?.lowercased() ?? ""
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if value.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "bmp"].contains(ext) { return "photo" }
        if value.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "ogg", "opus"].contains(ext) { return "waveform" }
        if value.hasPrefix("video/") || ["mp4", "mov", "mkv", "webm", "avi"].contains(ext) { return "film" }
        if value == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if value.hasPrefix("text/") || value.contains("json") || value.contains("xml")
            || ["md", "txt", "swift", "py", "js", "ts", "tsx", "json", "yaml", "yml", "toml", "sh"].contains(ext) {
            return "doc.text"
        }
        return "doc"
    }
}

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

struct HermesRemoteFileDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let selection: RemoteFileSelection

    @State private var snapshot: HermesFSTextSnapshot?
    @State private var originalSnapshot: HermesFSTextSnapshot?
    @State private var draft = ""
    @State private var image: UIImage?
    @State private var downloaded: HermesDownloadedFile?
    @State private var loading = false
    @State private var downloading = false
    @State private var saving = false
    @State private var editing = false
    @State private var failure: String?
    @State private var conflict: HermesFSTextSnapshot?

    var body: some View {
        NavigationStack {
            Group {
                if loading && snapshot == nil && failure == nil {
                    ProgressView("Reading file…")
                } else if editing {
                    editor
                } else if let snapshot {
                    preview(snapshot)
                } else {
                    ContentUnavailableView {
                        Label("Preview unavailable", systemImage: "doc")
                    } description: {
                        Text(failure ?? "This file can still be downloaded from Hermes.")
                    } actions: {
                        Button("Download") { Task { await download() } }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background(scheme))
            .navigationTitle(selection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { detailToolbar }
        }
        .task { await load() }
        .confirmationDialog(
            "File changed on Hermes",
            isPresented: Binding(
                get: { conflict != nil },
                set: { if !$0 { conflict = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reload server version") {
                if let conflict {
                    snapshot = conflict
                    originalSnapshot = conflict
                    draft = conflict.text
                    editing = false
                }
                self.conflict = nil
            }
            Button("Overwrite anyway", role: .destructive) {
                conflict = nil
                Task { await writeDraft(force: true) }
            }
            Button("Cancel", role: .cancel) { conflict = nil }
        } message: {
            Text("Another process or agent modified this file after Alice opened it. Overwriting would discard those newer changes.")
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly) }
        }
        if editing {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Cancel") {
                    draft = originalSnapshot?.text ?? snapshot?.text ?? ""
                    editing = false
                }
                Button("Save") { Task { await writeDraft(force: false) } }
                    .disabled(saving)
            }
        } else {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        draft = snapshot?.text ?? ""
                        editing = true
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await download() } } label: {
                    if downloading { ProgressView() } else { Image(systemName: "arrow.down.circle") }
                }
                .disabled(downloading)
                .accessibilityLabel("Download file")
                if let downloaded {
                    ShareLink(item: downloaded.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if saving {
                ProgressView().padding(.vertical, 6)
            }
            TextEditor(text: $draft)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func preview(_ file: HermesFSTextSnapshot) -> some View {
        if file.binary {
            if let image {
                // Tap for the image full screen, pinch to zoom.
                Image(uiImage: image).resizable().scaledToFit().padding()
                    .opensImageViewer(image)
            } else {
                binaryUnavailable(file)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    metadata(file)
                    if file.truncated {
                        Label("Preview truncated at 512 KB. Editing is disabled; download the full file instead.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(file.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
        }
    }

    private func metadata(_ file: HermesFSTextSnapshot) -> some View {
        HStack(spacing: 7) {
            Text(file.language.uppercased())
            Text("·")
            Text(ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))
            Text("·")
            Text(file.mimeType)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func binaryUnavailable(_ file: HermesFSTextSnapshot) -> some View {
        ContentUnavailableView {
            Label("Binary file", systemImage: "doc")
        } description: {
            Text("\(file.mimeType) · \(ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))")
        } actions: {
            Button("Download") { Task { await download() } }
            if let downloaded { ShareLink("Open or share", item: downloaded.url) }
        }
    }

    private var canEdit: Bool {
        guard selection.source == .workspace, !selection.readOnly, let snapshot else { return false }
        return !snapshot.binary && !snapshot.truncated
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            switch selection.source {
            case .managed:
                try await loadManagedPreview()
            case .workspace:
                let value = try await store.hermesFilesystemText(path: selection.path)
                snapshot = value
                originalSnapshot = value
                draft = value.text
                failure = nil
                if value.binary,
                   value.mimeType.lowercased().hasPrefix("image/"),
                   value.byteSize <= 16 * 1024 * 1024,
                   let binary = try? await store.hermesFilesystemData(path: selection.path) {
                    image = UIImage(data: binary.data)
                }
            }
        } catch {
            failure = reason(error)
        }
    }

    private func loadManagedPreview() async throws {
        let size = selection.size ?? 0
        let mime = selection.mimeType ?? "application/octet-stream"
        let textLike = isLikelyText(selection.name, mime: mime)
        let imageLike = mime.lowercased().hasPrefix("image/")
            || ["png", "jpg", "jpeg", "gif", "webp", "bmp"].contains(
                URL(fileURLWithPath: selection.name).pathExtension.lowercased()
            )

        // Managed reads stay on /api/files/read so Hermes' sensitive-file
        // denylist remains authoritative. Do not cross into /api/fs here.
        if textLike, size <= 512 * 1024 {
            let file = try await store.hermesFile(path: selection.path)
            let value = HermesFSTextSnapshot(
                path: file.path,
                text: String(decoding: file.data, as: UTF8.self),
                binary: false,
                byteSize: Int64(file.size),
                language: languageForName(file.name),
                mimeType: file.mimeType,
                truncated: false
            )
            snapshot = value
            originalSnapshot = value
            draft = value.text
            failure = nil
            return
        }

        if imageLike, size <= 16 * 1024 * 1024 {
            let file = try await store.hermesFile(path: selection.path)
            image = UIImage(data: file.data)
            snapshot = .init(
                path: file.path, text: "", binary: true,
                byteSize: Int64(file.size), language: "binary",
                mimeType: file.mimeType, truncated: false
            )
            failure = nil
            return
        }

        snapshot = .init(
            path: selection.path, text: "", binary: true,
            byteSize: size, language: "binary", mimeType: mime, truncated: false
        )
        failure = nil
    }

    private func isLikelyText(_ name: String, mime: String) -> Bool {
        let value = mime.lowercased()
        if value.hasPrefix("text/") || value.contains("json") || value.contains("xml")
            || value.contains("yaml") || value.contains("toml") || value.contains("javascript") {
            return true
        }
        return [
            "c", "conf", "cpp", "css", "csv", "go", "graphql", "h", "hpp", "html",
            "java", "js", "json", "jsx", "kt", "lua", "md", "mjs", "py", "rb", "rs",
            "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml", "zsh",
        ].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    private func languageForName(_ name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext.isEmpty ? "text" : ext
    }

    private func download() async {
        downloading = true
        defer { downloading = false }
        do {
            downloaded = try await {
                switch selection.source {
                case .managed:
                    try await store.downloadHermesFile(path: selection.path)
                case .workspace:
                    try await store.downloadHermesFilesystemFile(path: selection.path)
                }
            }()
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func writeDraft(force: Bool) async {
        guard let originalSnapshot else { return }
        saving = true
        defer { saving = false }
        do {
            if !force {
                let latest = try await store.hermesFilesystemText(path: selection.path)
                if latest.text != originalSnapshot.text
                    || latest.byteSize != originalSnapshot.byteSize
                    || latest.binary != originalSnapshot.binary
                    || latest.truncated != originalSnapshot.truncated {
                    conflict = latest
                    return
                }
            }
            _ = try await store.writeHermesFilesystemText(path: selection.path, content: draft)
            let fresh = try await store.hermesFilesystemText(path: selection.path)
            snapshot = fresh
            self.originalSnapshot = fresh
            draft = fresh.text
            editing = false
            failure = nil
        } catch {
            failure = reason(error)
        }
    }

    private func reason(_ error: Error) -> String {
        RemoteFileProblem.describe(error)
    }
}
