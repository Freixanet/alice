import SwiftUI

/// The projects the agent's work is filed under.
///
/// Two kinds, and the difference matters: the ones somebody made and named,
/// which can be renamed and removed here, and the ones the session tree
/// implies — a working directory the agent has been used in is a project
/// whether anybody said so or not, and there is nothing to edit about it.
struct HermesProfileChoice: Identifiable, Hashable {
    let id: String
    var label: String
}

/// First-class Hermes Projects. A Project owns workspace folders; sessions
/// belong to it because their real Hermes cwd is under one of those folders.
/// Nothing on this screen maintains a second iPhone-only project database.
struct ProjectsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles = [HermesProfileChoice(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var mine: [NamedProject] = []
    @State private var rows: [ProjectRow] = []
    @State private var activeProjectID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var creating = false
    @State private var createSeed: ProjectRow?
    @State private var inspecting: NamedProject?

    private var activeProjects: [NamedProject] { mine.filter { !$0.archived } }
    private var archivedProjects: [NamedProject] { mine.filter(\.archived) }
    private var inferred: [ProjectRow] {
        rows.filter { $0.isAuto && !$0.isHome }
    }
    private var home: ProjectRow? { rows.first(where: \.isHome) }

    var body: some View {
        DashboardList(
            title: "Projects", symbol: "folder", empty: "No projects yet.",
            loading: loading && mine.isEmpty && rows.isEmpty,
            failure: failure, isEmpty: false
        ) {
            List {
                if profiles.count > 1 {
                    Section {
                        Picker("Profile", selection: $selectedProfile) {
                            ForEach(profiles) { profile in
                                Text(profile.label).tag(profile.id)
                            }
                        }
                    } footer: {
                        Text("Projects belong to the selected Hermes profile.")
                    }
                }

                if activeProjects.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No named projects", systemImage: "folder.badge.plus",
                            description: Text("Projects group an agent’s work by folder. Create one here, or promote a workspace Hermes already found.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Projects") {
                        ForEach(activeProjects) { project in
                            Button {
                                inspecting = project
                            } label: {
                                projectRow(project)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.card(scheme))
                            .contextMenu {
                                Button {
                                    act { try await store.setActiveProject(project.id, profile: selectedProfile) }
                                } label: {
                                    Label(
                                        activeProjectID == project.id ? "Active Project" : "Use Project",
                                        systemImage: activeProjectID == project.id ? "checkmark.circle.fill" : "scope"
                                    )
                                }
                                .disabled(activeProjectID == project.id)

                                Button {
                                    act { try await store.setProjectArchived(project.id, archived: true, profile: selectedProfile) }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                        }
                    }
                }

                if !inferred.isEmpty {
                    Section {
                        ForEach(inferred) { row in
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.questionmark")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.label).font(.subheadline.weight(.medium))
                                    Text(projectDetail(row))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    // The full path used to sit here in
                                    // monospace, head-truncated, so what you
                                    // actually saw was "…/a/b/c" — the least
                                    // recognisable part of a folder you already
                                    // know by name. Kept, quietly, for anyone
                                    // who needs to be sure which folder it is.
                                    if let path = row.path {
                                        Text(shortPath(path))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button("Make Project") {
                                    createSeed = row
                                    creating = true
                                }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(.medium))
                            }
                            .padding(.vertical, 3)
                            .listRowBackground(Palette.card(scheme))
                        }
                    } header: {
                        Text("Folders Alice noticed")
                    } footer: {
                        Text("Alice keeps seeing work happen in these folders, but they have no name yet. Make one a project to give it a name and keep its conversations together.")
                    }
                }

                if let home, home.sessions > 0 {
                    Section {
                        LabeledContent(
                            "Not in any project", value: "\(home.sessions)"
                        )
                        .listRowBackground(Palette.card(scheme))
                    } footer: {
                        Text("Conversations that did not happen in one of the folders above. Nothing is wrong with them — they are simply unfiled.")
                    }
                }

                if !archivedProjects.isEmpty {
                    Section("Archived") {
                        ForEach(archivedProjects) { project in
                            HStack {
                                Text(project.name)
                                Spacer()
                                Button("Restore") {
                                    act { try await store.setProjectArchived(project.id, archived: false, profile: selectedProfile) }
                                }
                                .buttonStyle(.borderless)
                            }
                            .listRowBackground(Palette.card(scheme))
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createSeed = nil
                    creating = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $creating, onDismiss: { createSeed = nil }) {
            NewHermesProjectSheet(
                profile: selectedProfile,
                seed: createSeed,
                onCreated: { Task { await load() } }
            )
        }
        .sheet(item: $inspecting) { project in
            ProjectDetailSheet(
                project: project,
                profile: selectedProfile,
                activeID: activeProjectID,
                onChange: { Task { await load() } }
            )
        }
        .task {
            await loadProfiles()
            await load()
        }
        .onChange(of: selectedProfile) { _, _ in Task { await load() } }
        .onChange(of: store.dashboardReady) { _, ready in
            guard ready else { return }
            Task {
                await loadProfiles()
                await load()
            }
        }
        .refreshableWithFeedback { await load() }
    }

    private func projectRow(_ project: NamedProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: project.icon ?? "folder.fill")
                .foregroundStyle(tint(project))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if activeProjectID == project.id {
                        Text("Active")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(store.accent.primary(scheme))
                    }
                }
                if let path = project.primaryPath {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let row = rows.first(where: { $0.id == project.id }) {
                    Text(projectDetail(row)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }

    private func tint(_ project: NamedProject) -> Color {
        guard var hex = project.colour?.trimmingCharacters(in: .whitespaces),
              hex.hasPrefix("#") else { return store.accent.primary(scheme) }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else {
            return store.accent.primary(scheme)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The tail of a path, which is the part a person recognises. An absolute
    /// path from `/Users/...` is mostly prefix everyone already knows.
    private func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    private func projectDetail(_ row: ProjectRow) -> String {
        var parts = [row.sessions == 1 ? "1 session" : "\(row.sessions) sessions"]
        if row.tokens > 0 { parts.append("\(Insights.compact(row.tokens)) tokens") }
        if let when = row.lastActive {
            parts.append(when.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        do {
            profiles = try await store.hermesProfiles().map { HermesProfileChoice(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) {
                selectedProfile = "default"
            }
        } catch {
            // The default profile is still a valid choice; the page load below
            // will report the actionable connection error if it also fails.
        }
    }

    private func load() async {
        guard store.dashboardReady else {
            // App startup restores the Dashboard asynchronously. Do not flash a
            // false connection error while that restore is still in flight;
            // `onChange` below performs the real load as soon as it is ready.
            failure = nil
            return
        }
        loading = true
        defer { loading = false }

        let resolvedListing: (projects: [NamedProject], activeID: String?)
        do {
            resolvedListing = try await store.projectListing(profile: selectedProfile)
        } catch {
            failure = PlainWords.describe(error, doing: "load projects")
            return
        }

        let resolvedTree: [ProjectRow]
        do {
            resolvedTree = try await store.projects(profile: selectedProfile)
        } catch {
            failure = PlainWords.describe(error, doing: "load project folders")
            return
        }

        mine = resolvedListing.projects
        activeProjectID = resolvedListing.activeID
        rows = resolvedTree
        failure = nil
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                await load()
            } catch {
                failure = PlainWords.describe(error, doing: "update the project")
            }
        }
    }
}

private struct NewHermesProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let profile: String
    let seed: ProjectRow?
    let onCreated: () -> Void

    @State private var name: String
    @State private var folder: String
    @State private var detail = ""
    @State private var failure: String?
    @State private var saving = false

    init(profile: String, seed: ProjectRow?, onCreated: @escaping () -> Void) {
        self.profile = profile
        self.seed = seed
        self.onCreated = onCreated
        _name = State(initialValue: seed?.label ?? "")
        _folder = State(initialValue: seed?.path ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    TextField("/path/to/workspace", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                } header: {
                    Text("Workspace folder")
                } footer: {
                    Text("Hermes groups sessions into this Project by their working directory. You can leave it empty and add folders later.")
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(seed == nil ? "New Project" : "Make Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
        }
    }

    private func create() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.createProject(
                    profile: profile, name: title,
                    folder: workspace.isEmpty ? nil : workspace,
                    description: detail.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                onCreated()
                dismiss()
            } catch {
                failure = PlainWords.describe(error, doing: "create the project")
            }
        }
    }
}

private struct ProjectDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let profile: String
    let activeID: String?
    let onChange: () -> Void

    @State private var project: NamedProject
    @State private var name: String
    @State private var detail: String
    @State private var newFolder = ""
    @State private var failure: String?
    @State private var deleting = false
    @State private var saving = false

    init(
        project: NamedProject, profile: String, activeID: String?,
        onChange: @escaping () -> Void
    ) {
        self.profile = profile
        self.activeID = activeID
        self.onChange = onChange
        _project = State(initialValue: project)
        _name = State(initialValue: project.name)
        _detail = State(initialValue: project.detail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    if project.folders.isEmpty {
                        Text("No workspace folders yet.").foregroundStyle(.secondary)
                    }
                    ForEach(project.folders) { folder in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.label ?? folder.path)
                                    .font(.subheadline)
                                if folder.label != nil {
                                    Text(folder.path)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if folder.isPrimary {
                                Text("Primary")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(store.accent.primary(.light))
                            }
                        }
                        .contextMenu {
                            if !folder.isPrimary {
                                Button {
                                    mutate { try await store.setProjectPrimaryFolder(project.id, path: folder.path, profile: profile) }
                                } label: {
                                    Label("Make Primary", systemImage: "star")
                                }
                            }
                            Button(role: .destructive) {
                                mutate { try await store.removeProjectFolder(project.id, path: folder.path, profile: profile) }
                            } label: {
                                Label("Remove Folder", systemImage: "minus.circle")
                            }
                        }
                    }
                    HStack {
                        TextField("/path/to/workspace", text: $newFolder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                        Button {
                            let path = newFolder
                            newFolder = ""
                            mutate { try await store.addProjectFolder(project.id, path: path, profile: profile) }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Workspaces")
                } footer: {
                    Text("A session belongs to this Project when its Hermes working directory is inside one of these folders.")
                }

                Section {
                    Button {
                        mutate { try await store.setActiveProject(project.id, profile: profile) }
                    } label: {
                        Label(
                            activeID == project.id ? "Active Project" : "Use as Active Project",
                            systemImage: activeID == project.id ? "checkmark.circle.fill" : "scope"
                        )
                    }
                    .disabled(activeID == project.id)

                    Button {
                        mutate { try await store.setProjectArchived(project.id, archived: !project.archived, profile: profile) }
                    } label: {
                        Label(project.archived ? "Restore Project" : "Archive Project", systemImage: "archivebox")
                    }

                    Button(role: .destructive) { deleting = true } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .confirmationDialog(
                "Delete \(project.name)?", isPresented: $deleting,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await store.deleteProject(project.id, profile: profile)
                            onChange()
                            dismiss()
                        } catch { failure = PlainWords.describe(error, doing: "delete the project") }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sessions and files are kept. Removing the Project definition only removes its workspace grouping; those sessions may appear again as inferred workspaces.")
            }
        }
    }

    private func save() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.updateProject(
                    project.id, profile: profile, name: title,
                    description: detail.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await reload()
                onChange()
            } catch { failure = PlainWords.describe(error, doing: "save the project") }
        }
    }

    private func mutate(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                await reload()
                onChange()
            } catch { failure = PlainWords.describe(error, doing: "update the project") }
        }
    }

    private func reload() async {
        guard let fresh = try? await store.namedProjects(profile: profile)
            .first(where: { $0.id == project.id }) else { return }
        project = fresh
        name = fresh.name
        detail = fresh.detail
        failure = nil
    }
}

private struct MemoryEdit: Identifiable {
    let id = UUID()
    let targetID: String
    let targetLabel: String
    let original: String?
}

/// The curated memory Hermes really injects into future sessions. Provider
/// status can still be inspected, but editable entries are the built-in
/// USER.md / MEMORY.md store rather than an iPhone-side imitation.
struct MemoryScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles = [HermesProfileChoice(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var snapshot: MemorySnapshot?
    @State private var failure: String?
    @State private var loading = false
    @State private var editing: MemoryEdit?
    @State private var deleting: MemoryEdit?

    var body: some View {
        DashboardList(
            title: "Memory", symbol: "brain", empty: "Nothing remembered yet.",
            loading: loading && snapshot == nil, failure: failure, isEmpty: false
        ) {
            List {
                if profiles.count > 1 {
                    Section {
                        Picker("Profile", selection: $selectedProfile) {
                            ForEach(profiles) { profile in
                                Text(profile.label).tag(profile.id)
                            }
                        }
                    } footer: {
                        Text("Each Hermes profile has its own curated memory.")
                    }
                }

                if let snapshot {
                    ForEach(snapshot.targets) { target in
                        Section {
                            if target.entries.isEmpty {
                                Text(target.enabled ? "Nothing saved." : "Disabled for this profile.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(target.entries.enumerated()), id: \.offset) { _, entry in
                                    if target.enabled {
                                        Button {
                                            editing = MemoryEdit(
                                                targetID: target.id, targetLabel: target.label,
                                                original: entry
                                            )
                                        } label: {
                                            memoryEntry(entry)
                                        }
                                        .buttonStyle(.plain)
                                        .swipeActions {
                                            Button(role: .destructive) {
                                                deleting = MemoryEdit(
                                                    targetID: target.id,
                                                    targetLabel: target.label,
                                                    original: entry
                                                )
                                            } label: {
                                                Label("Forget", systemImage: "trash")
                                            }
                                        }
                                    } else {
                                        memoryEntry(entry)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(target.label)
                                Spacer()
                                Text("\(target.used)/\(target.limit)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 5) {
                                ProgressView(
                                    value: Double(target.used),
                                    total: Double(max(target.limit, 1))
                                )
                                Text(target.id == "user"
                                     ? "Stable facts and preferences about the user."
                                     : "Durable notes the agent should carry between sessions.")
                            }
                        }
                    }

                    Section {
                        LabeledContent(
                            "Configured provider",
                            value: snapshot.provider.isEmpty ? "Built-in only" : snapshot.provider
                        )
                        NavigationLink {
                            MemoryProvidersScreen(profile: selectedProfile) {
                                Task { await load() }
                            }
                        } label: {
                            Label("Memory Providers", systemImage: "externaldrive.badge.icloud")
                        }
                    } footer: {
                        Text("Edits above write Hermes' own USER.md and MEMORY.md. Provider management is profile-aware; new sessions load the updated memory configuration.")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let snapshot {
                        ForEach(snapshot.targets.filter(\.enabled)) { target in
                            Button(target.label) {
                                editing = MemoryEdit(
                                    targetID: target.id,
                                    targetLabel: target.label,
                                    original: nil
                                )
                            }
                        }
                    }
                } label: {
                    Label("Remember", systemImage: "plus")
                }
                .disabled(snapshot?.targets.contains(where: \.enabled) != true)
            }
        }
        .sheet(item: $editing) { edit in
            MemoryEntrySheet(edit: edit) { text in
                await save(edit, text: text)
            }
        }
        .confirmationDialog(
            "Forget this memory?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let deleting { Task { await forget(deleting) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            if let original = deleting?.original { Text(original) }
        }
        .task {
            await loadProfiles()
            await load()
        }
        .onChange(of: selectedProfile) { _, _ in Task { await load() } }
        .refreshableWithFeedback { await load() }
    }

    private func memoryEntry(_ entry: String) -> some View {
        Text(entry)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        if let choices = try? await store.hermesProfiles() {
            profiles = choices.map { HermesProfileChoice(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) {
                selectedProfile = "default"
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            snapshot = try await store.memorySnapshot(profile: selectedProfile)
            failure = nil
        } catch {
            failure = message(error)
        }
    }

    private func save(_ edit: MemoryEdit, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            snapshot = try await store.mutateMemory(
                profile: selectedProfile,
                target: edit.targetID,
                action: edit.original == nil ? "add" : "replace",
                content: trimmed,
                oldText: edit.original ?? ""
            )
            failure = nil
            return true
        } catch {
            failure = message(error)
            return false
        }
    }

    private func forget(_ edit: MemoryEdit) async {
        guard let original = edit.original else { return }
        do {
            snapshot = try await store.mutateMemory(
                profile: selectedProfile, target: edit.targetID,
                action: "remove", oldText: original
            )
            failure = nil
        } catch { failure = message(error) }
    }
}

private struct MemoryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let edit: MemoryEdit
    let save: (String) async -> Bool

    @State private var text: String
    @State private var saving = false

    init(edit: MemoryEdit, save: @escaping (String) async -> Bool) {
        self.edit = edit
        self.save = save
        _text = State(initialValue: edit.original ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(edit.targetLabel) {
                    TextField("What should Hermes remember?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .navigationTitle(edit.original == nil ? "Remember" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if await save(text) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
        }
    }
}

/// Usage as the dashboard totals it, which is not the same as the app adding
/// up sessions: this counts every call, including the small ones the agent
/// makes on its own to title a chat.
struct UsageScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var profiles = [HermesProfileChoice(id: "default", label: "Alice")]
    @State private var selectedProfile = "default"
    @State private var days = 30
    @State private var report: UsageReport?
    @State private var billing: BillingUsage?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        DashboardList(
            title: "Usage",
            symbol: "chart.bar",
            empty: "Nothing recorded yet.",
            loading: loading && report == nil,
            failure: failure,
            isEmpty: report == nil
        ) {
            if let report {
                List {
                    if profiles.count > 1 {
                        Section {
                            Picker("Profile", selection: $selectedProfile) {
                                ForEach(profiles) { Text($0.label).tag($0.id) }
                            }
                        }
                    }

                    Section {
                        Picker("Period", selection: $days) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .pickerStyle(.segmented)
                    }

                    if let billing, billing.available {
                        Section {
                            if !billing.planName.isEmpty {
                                row("Plan", billing.planName)
                            }
                            if !billing.status.isEmpty {
                                row("Status", billing.status)
                            }
                            if !billing.totalSpendable.isEmpty {
                                row("Spendable", billing.totalSpendable)
                            }
                            if !billing.subscriptionRemaining.isEmpty {
                                row("Subscription left", billing.subscriptionRemaining)
                            }
                            if !billing.topupRemaining.isEmpty {
                                row("Top-up left", billing.topupRemaining)
                            }
                            if let bar = billing.planBar {
                                usageBar("Plan usage", bar)
                            }
                            if let bar = billing.topupBar {
                                usageBar("Top-up usage", bar)
                            }
                            if !billing.renews.isEmpty {
                                row("Renews", billing.renews)
                            }
                        } header: {
                            Text("Account limit")
                        } footer: {
                            Text("Shown only when the active provider exposes a real subscription or spendable-balance view to Hermes.")
                        }
                    }

                    Section {
                        row("Sessions", "\(report.sessions)")
                        row("API calls", Insights.compact(report.calls))
                        row("Input tokens", Insights.compact(report.inputTokens))
                        row("Output tokens", Insights.compact(report.outputTokens))
                        if report.cacheReadTokens > 0 {
                            row("Cache-read tokens", Insights.compact(report.cacheReadTokens))
                        }
                        if report.reasoningTokens > 0 {
                            row("Reasoning tokens", Insights.compact(report.reasoningTokens))
                        }
                        if report.cost > 0 {
                            row("Cost", report.cost.formatted(.currency(code: "USD")))
                        }
                    } footer: {
                        Text("Hermes' own accounting for this profile over the last \(report.days) days.")
                    }

                    if !report.models.isEmpty {
                        Section("Models") {
                            ForEach(report.models) { model in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(model.name).font(.subheadline).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(Insights.compact(model.tokens))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 5) {
                                        if let provider = model.provider, !provider.isEmpty {
                                            Text(provider)
                                        }
                                        Text("\(model.sessions) sessions")
                                        Text("· \(model.calls) calls")
                                        if model.cost > 0 {
                                            Text("· \(model.cost.formatted(.currency(code: "USD")))")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .listRowBackground(Palette.card(scheme))
                            }
                        }
                    }

                    if !report.tools.isEmpty {
                        Section("Tools") {
                            ForEach(report.tools) { tool in
                                HStack {
                                    Text(tool.name).font(.subheadline.monospaced())
                                    Spacer(minLength: 8)
                                    Text(tool.share.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .listRowBackground(Palette.card(scheme))
                            }
                        }
                    }
                }
            }
        }
        .task {
            await loadProfiles()
            await load()
        }
        .onChange(of: selectedProfile) { _, _ in Task { await load() } }
        .onChange(of: days) { _, _ in Task { await load() } }
        .onChange(of: store.dashboardReady) { _, ready in
            guard ready else { return }
            Task { await loadProfiles(); await load() }
        }
        .refreshableWithFeedback { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .listRowBackground(Palette.card(scheme))
    }

    private func usageBar(_ label: String, _ bar: BillingUsage.Bar) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                if !bar.remaining.isEmpty { Text(bar.remaining).foregroundStyle(.secondary) }
            }
            ProgressView(value: min(1, max(0, bar.fillFraction)))
            if !bar.spent.isEmpty || !bar.total.isEmpty {
                Text([bar.spent, bar.total].filter { !$0.isEmpty }.joined(separator: " / "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadProfiles() async {
        guard store.dashboardReady else { return }
        if let choices = try? await store.hermesProfiles() {
            profiles = choices.map { HermesProfileChoice(id: $0.id, label: $0.label) }
            if !profiles.contains(where: { $0.id == selectedProfile }) { selectedProfile = "default" }
        }
    }

    private func load() async {
        guard store.dashboardReady else { failure = nil; return }
        loading = true
        defer { loading = false }
        do {
            report = try await store.usage(profile: selectedProfile, days: days)
            let modelInfo = try? await store.profileModelInfo(profile: selectedProfile)
            billing = modelInfo?.provider.lowercased() == "nous"
                ? (try? await store.billingUsage())
                : nil
            failure = nil
        } catch {
            failure = diagnosticMessage(error)
        }
    }
}

/// The three dashboard screens differ in their rows, not in how they behave
/// when there is nothing to show or nowhere to ask.
private struct DashboardList<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let symbol: String
    let empty: String
    let loading: Bool
    let failure: String?
    let isEmpty: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                // In a scroll view so it can be pulled. A bare
                // ContentUnavailableView does not scroll, and `.refreshable`
                // on something that cannot scroll does nothing at all — so an
                // error from a moment when the agent was unreachable stayed on
                // screen after the agent came back, with no way to ask again
                // short of leaving and returning.
                ScrollView {
                    ContentUnavailableView(
                        title, systemImage: symbol, description: Text(failure)
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            } else if isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        title, systemImage: symbol, description: Text(empty)
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            } else {
                content
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
    }
}

/// What went wrong, for the person reading the screen: cause first, and a
/// domain or code only when nothing else explains it. See `PlainWords`.
func diagnosticMessage(_ error: Error) -> String {
    PlainWords.describe(error)
}

func message(_ error: Error) -> String {
    diagnosticMessage(error)
}
