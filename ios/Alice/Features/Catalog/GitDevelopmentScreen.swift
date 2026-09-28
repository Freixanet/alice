import SwiftUI

private enum GitReviewScope: String, CaseIterable, Identifiable {
    case uncommitted
    case branch
    case sinceRef

    var id: String { rawValue }
    var label: String {
        switch self {
        case .uncommitted: "Uncommitted"
        case .branch: "Branch"
        case .sinceRef: "Since ref"
        }
    }
    var serverValue: String { self == .sinceRef ? "lastTurn" : rawValue }
}

private struct GitRepoCandidate: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var label: String
}

private struct GitDiffSelection: Identifiable, Hashable {
    var id: String { file.path + "|" + scope.rawValue + "|" + (base ?? "") }
    var file: GitReviewFile
    var scope: GitReviewScope
    var base: String?
}

private struct GitWorktreeRemoval: Identifiable, Hashable {
    var id: String { worktree.path }
    var worktree: GitWorktree
}

private struct GitBranchSwitch: Identifiable, Hashable {
    var id: String { branch.name }
    var branch: GitBranch
}

/// Remote-aware Git administration for the repository that lives beside Hermes.
/// Every operation goes through Hermes' authenticated `/api/git/*` mirror, so
/// an iPhone never runs git against its own filesystem by mistake.
struct GitDevelopmentScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @AppStorage("alice.git.repoPath") private var savedRepoPath = ""

    private let initialRepoPath: String?

    init(initialRepoPath: String? = nil) {
        self.initialRepoPath = initialRepoPath
    }

    @State private var repoPath = ""
    @State private var pathDraft = ""
    @State private var candidates: [GitRepoCandidate] = []
    @State private var status: GitRepoStatus?
    @State private var statusResolved = false
    @State private var worktrees: [GitWorktree] = []
    @State private var branches: [GitBranch] = []
    @State private var baseBranches: [GitBaseBranch] = []
    @State private var review: GitReviewListing?
    @State private var reviewScope: GitReviewScope = .uncommitted
    @State private var comparisonBase = ""
    @State private var ghAuth: GitHubAuthStatus?
    @State private var shipInfo: GitShipInfo?
    @State private var pullRequests: GitPullRequests?
    @State private var loading = false
    @State private var working = false
    @State private var failure: String?

    @State private var diffSelection: GitDiffSelection?
    @State private var showingCommit = false
    @State private var showingWorktreeAdd = false
    @State private var revertingFile: String?
    @State private var revertAll = false
    @State private var confirmingPush = false
    @State private var confirmingPR = false
    @State private var removingWorktree: GitWorktreeRemoval?
    @State private var switchingBranch: GitBranchSwitch?
    @State private var createdPRURL: URL?

    private var effectiveBase: String? {
        guard reviewScope == .sinceRef else { return nil }
        let value = comparisonBase.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        List {
            repositorySection
            if status != nil {
                statusSection
                reviewSection
                commitAndShipSection
                branchesSection
                worktreesSection
            } else if statusResolved && !repoPath.isEmpty {
                nonRepoSection
                worktreesSection
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
        .navigationTitle("Git")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .task {
            await loadCandidates()
            if repoPath.isEmpty {
                let requested = initialRepoPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                repoPath = !requested.isEmpty
                    ? requested
                    : (savedRepoPath.isEmpty ? (candidates.first?.path ?? "") : savedRepoPath)
                pathDraft = repoPath
            }
            if !repoPath.isEmpty { await refreshAll() }
        }
        .onChange(of: reviewScope) { _, _ in Task { await refreshReview() } }
        .refreshableWithFeedback { await refreshAll() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refreshAll() } } label: {
                    if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(loading || repoPath.isEmpty)
                .accessibilityLabel("Refresh Git repository")
            }
        }
        .sheet(item: $diffSelection) { selection in
            GitDiffSheet(repoPath: repoPath, selection: selection)
                .environment(store)
        }
        .sheet(isPresented: $showingCommit) {
            GitCommitSheet(repoPath: repoPath) {
                Task { await refreshAll() }
            }
            .environment(store)
        }
        .sheet(isPresented: $showingWorktreeAdd) {
            GitWorktreeAddSheet(
                repoPath: repoPath, branches: branches, baseBranches: baseBranches
            ) { created in
                repoPath = created.path
                pathDraft = created.path
                savedRepoPath = created.path
                Task { await refreshAll() }
            }
            .environment(store)
        }
        .confirmationDialog(
            revertingFile == nil ? "Discard all uncommitted changes?" : "Discard changes to this file?",
            isPresented: Binding(
                get: { revertingFile != nil || revertAll },
                set: { if !$0 { revertingFile = nil; revertAll = false } }
            ), titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                let file = revertingFile
                revertingFile = nil
                revertAll = false
                Task { await revert(file) }
            }
            Button("Cancel", role: .cancel) { revertingFile = nil; revertAll = false }
        } message: {
            Text(revertingFile == nil
                 ? "Tracked changes will be restored to HEAD and untracked files will be deleted. This cannot be undone."
                 : "Hermes will restore the tracked file to HEAD or delete it if it is untracked. This cannot be undone.")
        }
        .confirmationDialog("Push this branch?", isPresented: $confirmingPush, titleVisibility: .visible) {
            Button("Push") { Task { await push() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will push the current branch to its upstream, or create origin/<branch> as the upstream when needed.")
        }
        .confirmationDialog("Create a GitHub pull request?", isPresented: $confirmingPR, titleVisibility: .visible) {
            Button("Push & Create PR") { Task { await createPR() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will push the current branch if necessary, then run `gh pr create --fill` on the host.")
        }
        .confirmationDialog(
            "Remove worktree?",
            isPresented: Binding(
                get: { removingWorktree != nil },
                set: { if !$0 { removingWorktree = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Remove") {
                if let item = removingWorktree { Task { await removeWorktree(item.worktree, force: false) } }
            }
            Button("Force remove", role: .destructive) {
                if let item = removingWorktree { Task { await removeWorktree(item.worktree, force: true) } }
            }
            Button("Cancel", role: .cancel) { removingWorktree = nil }
        } message: {
            Text("Force remove can discard uncommitted work inside that worktree. The main worktree cannot be removed here.")
        }
        .confirmationDialog(
            "Switch branch?",
            isPresented: Binding(
                get: { switchingBranch != nil },
                set: { if !$0 { switchingBranch = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Switch") {
                if let item = switchingBranch { Task { await switchBranch(item.branch) } }
            }
            Button("Cancel", role: .cancel) { switchingBranch = nil }
        } message: {
            if let branch = switchingBranch?.branch {
                Text("Switch this worktree to `\(branch.name)`. Git will refuse if local changes cannot be preserved safely.")
            }
        }
        .alert("Pull request created", isPresented: Binding(
            get: { createdPRURL != nil }, set: { if !$0 { createdPRURL = nil } }
        )) {
            if let url = createdPRURL { Link("Open on GitHub", destination: url) }
            Button("OK", role: .cancel) { createdPRURL = nil }
        } message: {
            Text(createdPRURL?.absoluteString ?? "GitHub created the pull request.")
        }
    }

    private var repositorySection: some View {
        Section("Repository on Hermes host") {
            HStack(spacing: 8) {
                TextField("/path/to/repository", text: $pathDraft)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { selectPath(pathDraft) }
                Button("Open") { selectPath(pathDraft) }
                    .disabled(pathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
            .listRowBackground(Palette.card(scheme))

            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates) { candidate in
                        Button(candidate.label) { selectPath(candidate.path) }
                    }
                } label: {
                    Label("Choose a Hermes project folder", systemImage: "folder")
                }
                .listRowBackground(Palette.card(scheme))
            }

            if !repoPath.isEmpty {
                Text(repoPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var statusSection: some View {
        Section("Repository status") {
            if let status {
                HStack {
                    Label(
                        status.detached ? "Detached HEAD" : (status.branch ?? "Unknown branch"),
                        systemImage: "arrow.triangle.branch"
                    )
                    Spacer()
                    if let defaultBranch = status.defaultBranch {
                        Text("default: \(defaultBranch)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Palette.card(scheme))

                HStack(spacing: 10) {
                    statBadge("\(status.changed) changed", tint: status.changed == 0 ? .secondary : .orange)
                    if status.added > 0 { statBadge("+\(status.added)", tint: .green) }
                    if status.removed > 0 { statBadge("−\(status.removed)", tint: .red) }
                    if status.conflicted > 0 { statBadge("\(status.conflicted) conflicts", tint: .red) }
                }
                .listRowBackground(Palette.card(scheme))

                HStack {
                    Text("Remote divergence")
                    Spacer()
                    Text("↑ \(status.ahead)  ↓ \(status.behind)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle((status.ahead > 0 || status.behind > 0) ? .orange : .secondary)
                }
                .listRowBackground(Palette.card(scheme))

                if let ghAuth {
                    HStack {
                        Label("GitHub CLI", systemImage: "terminal")
                        Spacer()
                        Text(!ghAuth.available ? "Not installed" : (ghAuth.authenticated ? "Authenticated" : "Needs login"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ghAuth.authenticated ? .green : .orange)
                    }
                    .listRowBackground(Palette.card(scheme))
                    if ghAuth.available && !ghAuth.authenticated {
                        Text("Authenticate `gh` on the Hermes host (the Hermes `/github-auth` flow is the supported path), then refresh.")
                            .font(.caption).foregroundStyle(.secondary)
                            .listRowBackground(Palette.card(scheme))
                    }
                }
            }
        }
    }

    private var reviewSection: some View {
        Section("Review") {
            Picker("Scope", selection: $reviewScope) {
                ForEach(GitReviewScope.allCases) { scope in Text(scope.label).tag(scope) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Palette.card(scheme))

            if reviewScope == .sinceRef {
                HStack(spacing: 8) {
                    TextField("Base SHA or ref", text: $comparisonBase)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { Task { await refreshReview() } }
                    Button("Capture HEAD") { Task { await captureHead() } }
                }
                .listRowBackground(Palette.card(scheme))
                Text("Capture HEAD before a coding turn, then this scope shows everything changed since that exact revision.")
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            } else if let base = review?.base, !base.isEmpty {
                LabeledContent("Resolved base") {
                    Text(base).font(.caption2.monospaced()).textSelection(.enabled)
                }
                .listRowBackground(Palette.card(scheme))
            }

            if let review {
                if review.files.isEmpty {
                    Text(reviewScope == .uncommitted ? "Working tree clean." : "No files in this comparison.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                }
                ForEach(review.files) { file in
                    VStack(alignment: .leading, spacing: 7) {
                        Button {
                            diffSelection = .init(file: file, scope: reviewScope, base: effectiveBase)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(file.status).font(.caption.monospaced().bold()).foregroundStyle(statusTint(file.status))
                                Text(file.path).font(.caption.monospaced()).foregroundStyle(.primary).lineLimit(2)
                                Spacer(minLength: 8)
                                Text("+\(file.added) −\(file.removed)")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        if reviewScope == .uncommitted {
                            HStack(spacing: 8) {
                                if file.staged {
                                    Button("Unstage") { Task { await unstage(file.path) } }
                                } else {
                                    Button("Stage") { Task { await stage(file.path) } }
                                }
                                Button("Discard", role: .destructive) { revertingFile = file.path }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(working)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                if reviewScope == .uncommitted, !review.files.isEmpty {
                    HStack(spacing: 8) {
                        Button("Stage all") { Task { await stage(nil) } }
                        Button("Unstage all") { Task { await unstage(nil) } }
                        Button("Discard all", role: .destructive) { revertAll = true }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(working)
                    .listRowBackground(Palette.card(scheme))
                }
            } else if loading {
                ProgressView("Loading changes…").listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var commitAndShipSection: some View {
        Section("Commit & ship") {
            Button { showingCommit = true } label: {
                Label("Commit changes…", systemImage: "checkmark.circle")
            }
            .disabled(status?.changed == 0 || working)
            .listRowBackground(Palette.card(scheme))

            Button { confirmingPush = true } label: {
                Label("Push current branch", systemImage: "arrow.up.circle")
            }
            .disabled(status?.detached == true || working)
            .listRowBackground(Palette.card(scheme))

            if let current = shipInfo?.pullRequest {
                if let url = URL(string: current.url) {
                    Link(destination: url) {
                        HStack {
                            Label("PR #\(current.number)", systemImage: "arrow.triangle.pull")
                            Spacer()
                            Text(current.state.uppercased()).font(.caption2.weight(.bold))
                            Image(systemName: "arrow.up.right.square").font(.caption)
                        }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } else if shipInfo?.ghReady == true,
                      status?.branch != status?.defaultBranch,
                      status?.detached == false {
                Button { confirmingPR = true } label: {
                    Label("Create GitHub pull request", systemImage: "arrow.triangle.pull")
                }
                .disabled(working)
                .listRowBackground(Palette.card(scheme))
            }

            if let prs = pullRequests, !prs.pullRequests.isEmpty {
                DisclosureGroup("Repository pull requests (\(prs.pullRequests.count))") {
                    ForEach(prs.pullRequests) { pr in
                        if let url = URL(string: pr.url) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("#\(pr.number) \(pr.title.isEmpty ? pr.branch : pr.title)")
                                            .font(.subheadline).lineLimit(2)
                                        Spacer()
                                        if pr.draft { Text("DRAFT").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                                    }
                                    Text("\(pr.branch) · \(pr.state)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }

            Text("Hermes currently exposes push and GitHub PR creation over its remote Git API, but no general pull/fetch/clone endpoint. Alice does not emulate those with a hidden shell command.")
                .font(.caption).foregroundStyle(.secondary)
                .listRowBackground(Palette.card(scheme))
        }
    }

    private var branchesSection: some View {
        Section("Branches") {
            if branches.isEmpty {
                Text("No branches reported.").font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Palette.card(scheme))
            } else {
                DisclosureGroup("Branches (\(branches.count))") {
                    ForEach(branches) { branch in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(branch.name).font(.caption.monospaced()).lineLimit(2)
                                    if branch.isDefault { Text("DEFAULT").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                                    if branch.isRemote { Text("REMOTE").font(.caption2.weight(.bold)).foregroundStyle(.blue) }
                                }
                                if let path = branch.worktreePath {
                                    Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if branch.checkedOut {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if branch.isRemote {
                                Button("Worktree") { Task { await openRemoteBranchInWorktree(branch) } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            } else {
                                Button("Switch") { switchingBranch = .init(branch: branch) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .disabled(working)
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var worktreesSection: some View {
        Section("Worktrees") {
            Button { showingWorktreeAdd = true } label: {
                Label(status == nil ? "Initialize Git & create worktree…" : "Create worktree…", systemImage: "plus")
            }
            .disabled(repoPath.isEmpty || working)
            .listRowBackground(Palette.card(scheme))

            ForEach(worktrees) { tree in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tree.branch ?? (tree.detached ? "Detached" : "Unknown branch"))
                                .font(.subheadline.weight(.medium))
                            Text(tree.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if tree.isMain { Text("MAIN").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                        if tree.locked { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                    }
                    HStack(spacing: 8) {
                        if tree.path != repoPath {
                            Button("Open") { selectPath(tree.path) }
                        }
                        if !tree.isMain {
                            Button("Remove", role: .destructive) { removingWorktree = .init(worktree: tree) }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .listRowBackground(Palette.card(scheme))
            }
        }
    }

    private var nonRepoSection: some View {
        Section("Not a Git repository") {
            Text("Hermes did not find a repository at this path. Its worktree endpoint can initialize a plain project folder with an empty root commit, without silently committing existing files.")
                .font(.footnote).foregroundStyle(.secondary)
                .listRowBackground(Palette.card(scheme))
        }
    }

    private func statBadge(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func statusTint(_ status: String) -> Color {
        switch status.uppercased() {
        case "A", "?": .green
        case "D": .red
        case "U": .orange
        default: .blue
        }
    }

    private func selectPath(_ raw: String) {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        repoPath = path
        pathDraft = path
        savedRepoPath = path
        status = nil
        statusResolved = false
        review = nil
        Task { await refreshAll() }
    }

    private func loadCandidates() async {
        guard store.dashboardReady else { return }
        var found: [GitRepoCandidate] = []
        let profiles = (try? await store.routineProfiles()) ?? [(id: "default", label: "Alice")]
        for profile in profiles {
            guard let projects = try? await store.namedProjects(profile: profile.id) else { continue }
            for project in projects where !project.archived {
                for folder in project.folders {
                    let label = profiles.count > 1
                        ? "\(profile.label) · \(project.name) · \(folder.label ?? URL(fileURLWithPath: folder.path).lastPathComponent)"
                        : "\(project.name) · \(folder.label ?? URL(fileURLWithPath: folder.path).lastPathComponent)"
                    found.append(.init(path: folder.path, label: label))
                }
            }
        }
        var seen = Set<String>()
        candidates = found.filter { seen.insert($0.path).inserted }.sorted { $0.label < $1.label }
    }

    private func refreshAll() async {
        guard store.dashboardReady, !repoPath.isEmpty else {
            failure = store.dashboardReady ? nil : "Connect the Hermes dashboard to use remote Git."
            return
        }
        loading = true
        defer { loading = false }
        do {
            async let statusTask = store.gitRepoStatus(path: repoPath)
            async let worktreeTask = store.gitWorktrees(path: repoPath)
            async let branchTask = store.gitBranches(path: repoPath)
            async let baseTask = store.gitBaseBranches(path: repoPath)
            async let authTask = store.gitHubAuthStatus()
            let values = try await (statusTask, worktreeTask, branchTask, baseTask, authTask)
            status = values.0
            statusResolved = true
            worktrees = values.1
            branches = values.2
            baseBranches = values.3
            ghAuth = values.4
            failure = nil
            if status != nil {
                await refreshReview()
                await refreshShipping()
            } else {
                review = nil
                shipInfo = nil
                pullRequests = nil
            }
        } catch {
            statusResolved = true
            failure = reason(error)
        }
    }

    private func refreshReview() async {
        guard status != nil else { return }
        if reviewScope == .sinceRef && effectiveBase == nil {
            review = .init(files: [], base: nil)
            return
        }
        do {
            review = try await store.gitReviewList(
                path: repoPath, scope: reviewScope.serverValue, base: effectiveBase
            )
        } catch { failure = reason(error) }
    }

    private func refreshShipping() async {
        do {
            async let shipTask = store.gitShipInfo(path: repoPath)
            let names = branches.map(\.name)
            async let prsTask = store.gitPullRequests(path: repoPath, branches: names)
            let values = try await (shipTask, prsTask)
            shipInfo = values.0
            pullRequests = values.1
        } catch {
            // Git remains usable without GitHub; keep the exact failure visible
            // only if gh claimed to be ready and then failed unexpectedly.
            if ghAuth?.authenticated == true { failure = reason(error) }
        }
    }

    private func captureHead() async {
        do {
            comparisonBase = try await store.gitRevParse(path: repoPath) ?? ""
            await refreshReview()
        } catch { failure = reason(error) }
    }

    private func stage(_ file: String?) async {
        await mutation {
            try await store.gitStage(path: repoPath, file: file)
        }
    }

    private func unstage(_ file: String?) async {
        await mutation {
            try await store.gitUnstage(path: repoPath, file: file)
        }
    }

    private func revert(_ file: String?) async {
        await mutation {
            try await store.gitRevert(path: repoPath, file: file)
        }
    }

    private func push() async {
        await mutation {
            try await store.gitPush(path: repoPath)
        }
    }

    private func createPR() async {
        working = true
        defer { working = false }
        do {
            let value = try await store.gitCreatePullRequest(path: repoPath)
            createdPRURL = URL(string: value)
            await refreshAll()
        } catch { failure = reason(error) }
    }

    private func switchBranch(_ branch: GitBranch) async {
        switchingBranch = nil
        working = true
        defer { working = false }
        do {
            _ = try await store.gitSwitchBranch(path: repoPath, branch: branch.name)
            await refreshAll()
        } catch { failure = reason(error) }
    }

    private func openRemoteBranchInWorktree(_ branch: GitBranch) async {
        working = true
        defer { working = false }
        do {
            let created = try await store.gitAddWorktree(path: repoPath, existingBranch: branch.name)
            repoPath = created.path
            pathDraft = created.path
            savedRepoPath = created.path
            await refreshAll()
        } catch { failure = reason(error) }
    }

    private func removeWorktree(_ tree: GitWorktree, force: Bool) async {
        removingWorktree = nil
        working = true
        defer { working = false }
        do {
            _ = try await store.gitRemoveWorktree(path: repoPath, worktreePath: tree.path, force: force)
            if repoPath == tree.path, let main = worktrees.first(where: \.isMain) {
                repoPath = main.path
                pathDraft = main.path
                savedRepoPath = main.path
            }
            await refreshAll()
        } catch { failure = reason(error) }
    }

    private func mutation(_ operation: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await operation()
            await refreshAll()
        } catch { failure = reason(error) }
    }

    private func reason(_ error: Error) -> String {
        PlainWords.describe(error, doing: "run the Git command")
    }
}

private enum GitDiffMode: String, CaseIterable, Identifiable {
    case working
    case staged
    case head
    var id: String { rawValue }
    var label: String {
        switch self {
        case .working: "Working"
        case .staged: "Staged"
        case .head: "HEAD"
        }
    }
}

private struct GitDiffSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let repoPath: String
    let selection: GitDiffSelection

    @State private var mode: GitDiffMode = .working
    @State private var diff = ""
    @State private var loading = false
    @State private var failure: String?

    private var allowedModes: [GitDiffMode] {
        guard selection.scope == .uncommitted else { return [.working] }
        return selection.file.staged ? [.working, .staged, .head] : [.working, .head]
    }

    var body: some View {
        NavigationStack {
            List {
                if allowedModes.count > 1 {
                    Section {
                        Picker("Diff", selection: $mode) {
                            ForEach(allowedModes) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    if loading {
                        ProgressView("Loading diff…")
                    } else if let failure {
                        Text(failure).foregroundStyle(.red).font(.footnote)
                    } else if diff.isEmpty {
                        Text("No diff for this view.").foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(displayDiff)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(minWidth: 720, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text(selection.file.path)
                } footer: {
                    if diff.count > 300_000 {
                        Text("Alice displays the first 300,000 characters to keep very large diffs responsive on iPhone.")
                    }
                }
            }
            .navigationTitle("Diff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { mode = selection.file.staged ? .staged : .working; await load() }
            .onChange(of: mode) { _, _ in Task { await load() } }
        }
    }

    private var displayDiff: String {
        guard diff.count > 300_000 else { return diff }
        return String(diff.prefix(300_000)) + "\n\n# Alice display truncated"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            if mode == .head && selection.scope == .uncommitted {
                diff = try await store.gitFileDiff(path: repoPath, file: selection.file.path)
            } else {
                diff = try await store.gitReviewDiff(
                    path: repoPath, file: selection.file.path,
                    scope: selection.scope.serverValue, base: selection.base,
                    staged: mode == .staged
                )
            }
            failure = nil
        } catch {
            failure = PlainWords.describe(error, doing: "load the diff")
        }
    }
}

private struct GitCommitSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let repoPath: String
    let onCommitted: () -> Void

    @State private var message = ""
    @State private var push = false
    @State private var context: GitCommitContext?
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Commit message") {
                    TextField("Summary", text: $message, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                    Toggle("Push after commit", isOn: $push)
                    Text("If nothing is staged, Hermes stages every current change before committing. Stage individual files first when you want a partial commit.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let context, !context.recentSubjects.isEmpty {
                    Section("Recent commit style") {
                        ForEach(context.recentSubjects, id: \.self) { subject in
                            Text(subject).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                if let context, !context.diff.isEmpty {
                    Section("What will commit") {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(context.diff)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(minWidth: 680, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                    }
                } else if loading {
                    Section { ProgressView("Reading commit context…") }
                }

                if let failure { Section { Text(failure).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle(push ? "Commit & Push" : "Commit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(push ? "Commit & Push" : "Commit") { commit() }
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .task { await loadContext() }
        }
    }

    private func loadContext() async {
        loading = true
        defer { loading = false }
        do { context = try await store.gitCommitContext(path: repoPath) }
        catch { failure = PlainWords.describe(error, doing: "read the commit") }
    }

    private func commit() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.gitCommit(path: repoPath, message: trimmed, push: push)
                onCommitted()
                dismiss()
            } catch {
                failure = PlainWords.describe(error, doing: "create the commit")
            }
        }
    }
}

private struct GitWorktreeAddSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let repoPath: String
    let branches: [GitBranch]
    let baseBranches: [GitBaseBranch]
    let onCreated: (GitWorktreeCreation) -> Void

    @State private var existing = false
    @State private var name = ""
    @State private var branch = ""
    @State private var base = ""
    @State private var existingBranch = ""
    @State private var saving = false
    @State private var failure: String?

    private var availableExisting: [GitBranch] {
        branches.filter { !$0.checkedOut }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $existing) {
                        Text("New branch").tag(false)
                        Text("Existing branch").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if existing {
                    Section("Existing branch") {
                        if availableExisting.isEmpty {
                            Text("Every reported local branch is already checked out and Hermes reported no unused remote branch.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Picker("Branch", selection: $existingBranch) {
                                Text("Choose…").tag("")
                                ForEach(availableExisting) { value in
                                    Text(value.name).tag(value.name)
                                }
                            }
                        }
                        Text("A remote-tracking branch such as `origin/feature` becomes a local tracking branch in the new worktree rather than a detached HEAD.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("New worktree") {
                        TextField("Worktree name (optional)", text: $name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Branch name (optional)", text: $branch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("Base", selection: $base) {
                            Text("Current HEAD").tag("")
                            ForEach(baseBranches) { value in
                                Text(value.isDefault ? "\(value.name) · default" : value.name).tag(value.name)
                            }
                        }
                    }
                }

                Section {
                    Text("Hermes creates worktrees under `.worktrees/` beside the main repository. If this path is a plain folder, Hermes initializes Git with an empty root commit first and leaves existing files untracked.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let failure { Section { Text(failure).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(saving || (existing && existingBranch.isEmpty))
                }
            }
            .task {
                if base.isEmpty { base = baseBranches.first(where: \.isDefault)?.name ?? "" }
            }
        }
    }

    private func create() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let created: GitWorktreeCreation
                if existing {
                    created = try await store.gitAddWorktree(path: repoPath, existingBranch: existingBranch)
                } else {
                    created = try await store.gitAddWorktree(
                        path: repoPath, name: name, branch: branch, base: base
                    )
                }
                onCreated(created)
                dismiss()
            } catch {
                failure = PlainWords.describe(error, doing: "create the worktree")
            }
        }
    }
}
