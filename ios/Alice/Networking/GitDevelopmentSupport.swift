import Foundation

struct GitStatusFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var staged: Bool
    var unstaged: Bool
    var untracked: Bool
    var conflicted: Bool
}

struct GitRepoStatus: Hashable, Sendable {
    var branch: String?
    var defaultBranch: String?
    var detached: Bool
    var ahead: Int
    var behind: Int
    var staged: Int
    var unstaged: Int
    var untracked: Int
    var conflicted: Int
    var changed: Int
    var added: Int
    var removed: Int
    var files: [GitStatusFile]
}

struct GitHubAuthStatus: Hashable, Sendable {
    var available: Bool
    var authenticated: Bool
}

struct GitWorktree: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var branch: String?
    var isMain: Bool
    var detached: Bool
    var locked: Bool
}

struct GitBranch: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var checkedOut: Bool
    var isDefault: Bool
    var isRemote: Bool
    var worktreePath: String?
}

struct GitBaseBranch: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var isRemote: Bool
    var isDefault: Bool
}

struct GitReviewFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var added: Int
    var removed: Int
    var status: String
    var staged: Bool
}

struct GitReviewListing: Hashable, Sendable {
    var files: [GitReviewFile]
    var base: String?
}

struct GitCommitContext: Hashable, Sendable {
    var diff: String
    var recentSubjects: [String]
}

struct GitPullRequest: Identifiable, Hashable, Sendable {
    var id: Int { number }
    var branch: String
    var draft: Bool
    var number: Int
    var state: String
    var title: String
    var url: String
}

struct GitPullRequests: Hashable, Sendable {
    var ghReady: Bool
    var pullRequests: [GitPullRequest]
}

struct GitShipInfo: Hashable, Sendable {
    var ghReady: Bool
    var pullRequest: GitPullRequest?
}

struct GitWorktreeCreation: Hashable, Sendable {
    var path: String
    var branch: String
    var repoRoot: String
}

extension DashboardClient {
    /// Hermes returns a JSON `null` when the path is not a repository. The
    /// dashboard transport currently maps a top-level null to an empty map,
    /// so an empty object is the one intentional nullable case here.
    func gitRepoStatus(path: String) async throws -> GitRepoStatus? {
        try Self.gitRepoStatus(from: await get("api/git/status?path=\(Self.gitQuery(path))"))
    }

    func gitHubAuthStatus(refresh: Bool = false) async throws -> GitHubAuthStatus {
        let suffix = refresh ? "?refresh=true" : ""
        return try Self.gitHubAuthStatus(from: await get("api/git/gh-auth\(suffix)"))
    }

    func gitWorktrees(path: String) async throws -> [GitWorktree] {
        try Self.gitWorktrees(from: await get("api/git/worktrees?path=\(Self.gitQuery(path))"))
    }

    func gitBranches(path: String) async throws -> [GitBranch] {
        try Self.gitBranches(from: await get("api/git/branches?path=\(Self.gitQuery(path))"))
    }

    func gitBaseBranches(path: String) async throws -> [GitBaseBranch] {
        try Self.gitBaseBranches(from: await get("api/git/base-branches?path=\(Self.gitQuery(path))"))
    }

    func gitReviewList(path: String, scope: String, base: String? = nil) async throws -> GitReviewListing {
        var route = "api/git/review/list?path=\(Self.gitQuery(path))&scope=\(Self.gitQuery(scope))"
        if let base = Self.gitString(base) { route += "&base=\(Self.gitQuery(base))" }
        return try Self.gitReviewList(from: await get(route))
    }

    func gitReviewDiff(
        path: String, file: String, scope: String, base: String? = nil, staged: Bool = false
    ) async throws -> String {
        var route = "api/git/review/diff?path=\(Self.gitQuery(path))&file=\(Self.gitQuery(file))"
        route += "&scope=\(Self.gitQuery(scope))&staged=\(staged ? "true" : "false")"
        if let base = Self.gitString(base) { route += "&base=\(Self.gitQuery(base))" }
        let object = try await get(route)
        guard let diff = object["diff"] as? String else { throw Failure.unreadable }
        return diff
    }

    func gitFileDiff(path: String, file: String) async throws -> String {
        let object = try await get(
            "api/git/file-diff?path=\(Self.gitQuery(path))&file=\(Self.gitQuery(file))"
        )
        guard let diff = object["diff"] as? String else { throw Failure.unreadable }
        return diff
    }

    func gitCommitContext(path: String) async throws -> GitCommitContext {
        try Self.gitCommitContext(from: await get("api/git/review/commit-context?path=\(Self.gitQuery(path))"))
    }

    func gitRevParse(path: String, ref: String? = nil) async throws -> String? {
        var route = "api/git/review/rev-parse?path=\(Self.gitQuery(path))"
        if let ref = Self.gitString(ref) { route += "&ref=\(Self.gitQuery(ref))" }
        let object = try await get(route)
        if object["sha"] is NSNull { return nil }
        if let sha = object["sha"] as? String { return Self.gitString(sha) }
        throw Failure.unreadable
    }

    func gitShipInfo(path: String) async throws -> GitShipInfo {
        try Self.gitShipInfo(from: await get("api/git/review/ship-info?path=\(Self.gitQuery(path))"))
    }

    func gitPullRequests(path: String, branches: [String], numbers: [Int] = []) async throws -> GitPullRequests {
        try Self.gitPullRequests(from: await send("POST", "api/git/review/pr-list", [
            "path": path, "branches": branches, "numbers": numbers,
        ]))
    }

    func gitStage(path: String, file: String? = nil) async throws {
        try await gitOK("api/git/review/stage", path: path, file: file)
    }

    func gitUnstage(path: String, file: String? = nil) async throws {
        try await gitOK("api/git/review/unstage", path: path, file: file)
    }

    func gitRevert(path: String, file: String? = nil) async throws {
        try await gitOK("api/git/review/revert", path: path, file: file)
    }

    func gitCommit(path: String, message: String, push: Bool) async throws {
        let object = try await send("POST", "api/git/review/commit", [
            "path": path, "message": message, "push": push,
        ])
        guard object["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func gitPush(path: String) async throws {
        let object = try await send("POST", "api/git/review/push", ["path": path])
        guard object["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    func gitCreatePullRequest(path: String) async throws -> String {
        let object = try await send("POST", "api/git/review/create-pr", ["path": path])
        guard let url = Self.gitString(object["url"]) else { throw Failure.unreadable }
        return url
    }

    func gitAddWorktree(
        path: String, name: String? = nil, branch: String? = nil,
        base: String? = nil, existingBranch: String? = nil
    ) async throws -> GitWorktreeCreation {
        var body: [String: Any] = ["path": path]
        if let name = Self.gitString(name) { body["name"] = name }
        if let branch = Self.gitString(branch) { body["branch"] = branch }
        if let base = Self.gitString(base) { body["base"] = base }
        if let existingBranch = Self.gitString(existingBranch) { body["existingBranch"] = existingBranch }
        return try Self.gitWorktreeCreation(
            from: await send("POST", "api/git/worktree/add", body)
        )
    }

    func gitRemoveWorktree(path: String, worktreePath: String, force: Bool) async throws -> String {
        let object = try await send("POST", "api/git/worktree/remove", [
            "path": path, "worktreePath": worktreePath, "force": force,
        ])
        guard let removed = Self.gitString(object["removed"]) else { throw Failure.unreadable }
        return removed
    }

    func gitSwitchBranch(path: String, branch: String) async throws -> String {
        let object = try await send("POST", "api/git/branch/switch", [
            "path": path, "branch": branch,
        ])
        guard let saved = Self.gitString(object["branch"]) else { throw Failure.unreadable }
        return saved
    }

    private func gitOK(_ route: String, path: String, file: String?) async throws {
        var body: [String: Any] = ["path": path]
        if let file = Self.gitString(file) { body["file"] = file }
        let object = try await send("POST", route, body)
        guard object["ok"] as? Bool == true else { throw Failure.unreadable }
    }

    static func gitRepoStatus(from object: [String: Any]) throws -> GitRepoStatus? {
        if object.isEmpty { return nil }
        guard let detached = object["detached"] as? Bool,
              let ahead = Self.gitInt(object["ahead"]),
              let behind = Self.gitInt(object["behind"]),
              let staged = Self.gitInt(object["staged"]),
              let unstaged = Self.gitInt(object["unstaged"]),
              let untracked = Self.gitInt(object["untracked"]),
              let conflicted = Self.gitInt(object["conflicted"]),
              let changed = Self.gitInt(object["changed"]),
              let added = Self.gitInt(object["added"]),
              let removed = Self.gitInt(object["removed"]),
              let rows = object["files"] as? [[String: Any]] else { throw Failure.unreadable }
        let files = try rows.map { row -> GitStatusFile in
            guard let path = Self.gitString(row["path"]),
                  let fileStaged = row["staged"] as? Bool,
                  let fileUnstaged = row["unstaged"] as? Bool,
                  let fileUntracked = row["untracked"] as? Bool,
                  let fileConflicted = row["conflicted"] as? Bool else { throw Failure.unreadable }
            return .init(
                path: path, staged: fileStaged, unstaged: fileUnstaged,
                untracked: fileUntracked, conflicted: fileConflicted
            )
        }
        return .init(
            branch: Self.gitString(object["branch"]), defaultBranch: Self.gitString(object["defaultBranch"]),
            detached: detached, ahead: ahead, behind: behind, staged: staged, unstaged: unstaged,
            untracked: untracked, conflicted: conflicted, changed: changed, added: added,
            removed: removed, files: files
        )
    }

    static func gitHubAuthStatus(from object: [String: Any]) throws -> GitHubAuthStatus {
        guard let available = object["available"] as? Bool,
              let authenticated = object["authenticated"] as? Bool else { throw Failure.unreadable }
        return .init(available: available, authenticated: authenticated)
    }

    static func gitWorktrees(from object: [String: Any]) throws -> [GitWorktree] {
        guard let rows = object["worktrees"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let path = Self.gitString(row["path"]),
                  let isMain = row["isMain"] as? Bool,
                  let detached = row["detached"] as? Bool,
                  let locked = row["locked"] as? Bool else { throw Failure.unreadable }
            return .init(path: path, branch: Self.gitString(row["branch"]), isMain: isMain, detached: detached, locked: locked)
        }
    }

    static func gitBranches(from object: [String: Any]) throws -> [GitBranch] {
        guard let rows = object["branches"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let name = Self.gitString(row["name"]),
                  let checkedOut = row["checkedOut"] as? Bool,
                  let isDefault = row["isDefault"] as? Bool,
                  let isRemote = row["isRemote"] as? Bool else { throw Failure.unreadable }
            return .init(
                name: name, checkedOut: checkedOut, isDefault: isDefault,
                isRemote: isRemote, worktreePath: Self.gitString(row["worktreePath"])
            )
        }
    }

    static func gitBaseBranches(from object: [String: Any]) throws -> [GitBaseBranch] {
        guard let rows = object["branches"] as? [[String: Any]] else { throw Failure.unreadable }
        return try rows.map { row in
            guard let name = Self.gitString(row["name"]),
                  let isRemote = row["isRemote"] as? Bool,
                  let isDefault = row["isDefault"] as? Bool else { throw Failure.unreadable }
            return .init(name: name, isRemote: isRemote, isDefault: isDefault)
        }
    }

    static func gitReviewList(from object: [String: Any]) throws -> GitReviewListing {
        guard let rows = object["files"] as? [[String: Any]] else { throw Failure.unreadable }
        let files = try rows.map { row -> GitReviewFile in
            guard let path = Self.gitString(row["path"]),
                  let added = Self.gitInt(row["added"]),
                  let removed = Self.gitInt(row["removed"]),
                  let status = Self.gitString(row["status"]),
                  let staged = row["staged"] as? Bool else { throw Failure.unreadable }
            return .init(path: path, added: added, removed: removed, status: status, staged: staged)
        }
        if let raw = object["base"], !(raw is NSNull), !(raw is String) { throw Failure.unreadable }
        return .init(files: files, base: Self.gitString(object["base"]))
    }

    static func gitCommitContext(from object: [String: Any]) throws -> GitCommitContext {
        guard let diff = object["diff"] as? String,
              let recent = object["recent"] as? String else { throw Failure.unreadable }
        let subjects = recent.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return .init(diff: diff, recentSubjects: subjects)
    }

    static func gitShipInfo(from object: [String: Any]) throws -> GitShipInfo {
        guard let ready = object["ghReady"] as? Bool else { throw Failure.unreadable }
        if object["pr"] is NSNull || object["pr"] == nil { return .init(ghReady: ready, pullRequest: nil) }
        guard let row = object["pr"] as? [String: Any] else { throw Failure.unreadable }
        return .init(ghReady: ready, pullRequest: try Self.gitPullRequest(from: row, branchFallback: ""))
    }

    static func gitPullRequests(from object: [String: Any]) throws -> GitPullRequests {
        guard let ready = object["ghReady"] as? Bool,
              let rows = object["prs"] as? [[String: Any]] else { throw Failure.unreadable }
        return .init(ghReady: ready, pullRequests: try rows.map { try Self.gitPullRequest(from: $0, branchFallback: "") })
    }

    static func gitWorktreeCreation(from object: [String: Any]) throws -> GitWorktreeCreation {
        guard let path = Self.gitString(object["path"]),
              let branch = Self.gitString(object["branch"]),
              let root = Self.gitString(object["repoRoot"]) else { throw Failure.unreadable }
        return .init(path: path, branch: branch, repoRoot: root)
    }

    private static func gitPullRequest(from row: [String: Any], branchFallback: String) throws -> GitPullRequest {
        guard let number = Self.gitInt(row["number"]), number > 0,
              let state = Self.gitString(row["state"]),
              let url = Self.gitString(row["url"]) else { throw Failure.unreadable }
        return .init(
            branch: Self.gitString(row["branch"]) ?? Self.gitString(row["headRefName"]) ?? branchFallback,
            draft: row["draft"] as? Bool ?? row["isDraft"] as? Bool ?? false,
            number: number, state: state, title: row["title"] as? String ?? "", url: url
        )
    }

    private static func gitString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func gitInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func gitQuery(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+#"))
        ) ?? value
    }
}
