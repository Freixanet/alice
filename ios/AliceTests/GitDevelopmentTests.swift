import XCTest
@testable import Alice

final class GitDevelopmentTests: XCTestCase {
    func testRepoStatusPreservesBranchDivergenceAndFileFlags() throws {
        let parsed = try XCTUnwrap(DashboardClient.gitRepoStatus(from: [
            "branch": "feature/test", "defaultBranch": "main", "detached": false,
            "ahead": 2, "behind": 1, "staged": 1, "unstaged": 2,
            "untracked": 1, "conflicted": 1, "changed": 3,
            "added": 42, "removed": 7,
            "files": [
                ["path": "A.swift", "staged": true, "unstaged": false, "untracked": false, "conflicted": false],
                ["path": "new.txt", "staged": false, "unstaged": true, "untracked": true, "conflicted": false],
                ["path": "conflict.md", "staged": false, "unstaged": false, "untracked": false, "conflicted": true],
            ],
        ]))

        XCTAssertEqual(parsed.branch, "feature/test")
        XCTAssertEqual(parsed.defaultBranch, "main")
        XCTAssertEqual(parsed.ahead, 2)
        XCTAssertEqual(parsed.behind, 1)
        XCTAssertEqual(parsed.changed, 3)
        XCTAssertEqual(parsed.added, 42)
        XCTAssertEqual(parsed.files[0].staged, true)
        XCTAssertEqual(parsed.files[1].untracked, true)
        XCTAssertEqual(parsed.files[2].conflicted, true)
    }

    func testTopLevelNullTransportShapeMeansNonRepoButMalformedStatusThrows() throws {
        XCTAssertNil(try DashboardClient.gitRepoStatus(from: [:]))
        XCTAssertThrowsError(try DashboardClient.gitRepoStatus(from: [
            "branch": "main", "detached": false,
        ]))
    }

    func testWorktreeAndBranchParsersPreserveRemoteAndCheckoutState() throws {
        let trees = try DashboardClient.gitWorktrees(from: [
            "worktrees": [
                ["path": "/repo", "branch": "main", "isMain": true, "detached": false, "locked": false],
                ["path": "/repo/.worktrees/x", "branch": NSNull(), "isMain": false, "detached": true, "locked": true],
            ],
        ])
        let branches = try DashboardClient.gitBranches(from: [
            "branches": [
                ["name": "main", "checkedOut": true, "isDefault": true, "isRemote": false, "worktreePath": "/repo"],
                ["name": "origin/feature", "checkedOut": false, "isDefault": false, "isRemote": true, "worktreePath": NSNull()],
            ],
        ])
        let bases = try DashboardClient.gitBaseBranches(from: [
            "branches": [
                ["name": "origin/main", "isRemote": true, "isDefault": true],
            ],
        ])

        XCTAssertTrue(trees[0].isMain)
        XCTAssertTrue(trees[1].detached)
        XCTAssertTrue(trees[1].locked)
        XCTAssertTrue(branches[1].isRemote)
        XCTAssertNil(branches[1].worktreePath)
        XCTAssertEqual(bases.first?.name, "origin/main")
        XCTAssertEqual(bases.first?.isDefault, true)
    }

    func testReviewListingPreservesCountsStageAndResolvedBase() throws {
        let review = try DashboardClient.gitReviewList(from: [
            "base": "abc123",
            "files": [
                ["path": "ios/A.swift", "added": 12, "removed": 4, "status": "M", "staged": true],
                ["path": "README.md", "added": 3, "removed": 0, "status": "?", "staged": false],
            ],
        ])

        XCTAssertEqual(review.base, "abc123")
        XCTAssertEqual(review.files.count, 2)
        XCTAssertEqual(review.files[0].added, 12)
        XCTAssertTrue(review.files[0].staged)
        XCTAssertEqual(review.files[1].status, "?")
    }

    func testCommitContextSplitsRecentSubjectsWithoutLosingDiff() throws {
        let context = try DashboardClient.gitCommitContext(from: [
            "diff": "diff --git a/a b/a\n+hello\n",
            "recent": "feat: one\nfix: two\n",
        ])
        XCTAssertTrue(context.diff.contains("+hello"))
        XCTAssertEqual(context.recentSubjects, ["feat: one", "fix: two"])
    }

    func testGitHubAndShipInfoKeepAuthAndCurrentPR() throws {
        let auth = try DashboardClient.gitHubAuthStatus(from: [
            "available": true, "authenticated": true,
        ])
        let ship = try DashboardClient.gitShipInfo(from: [
            "ghReady": true,
            "pr": ["url": "https://github.com/acme/repo/pull/42", "state": "OPEN", "number": 42],
        ])

        XCTAssertTrue(auth.available)
        XCTAssertTrue(auth.authenticated)
        XCTAssertTrue(ship.ghReady)
        XCTAssertEqual(ship.pullRequest?.number, 42)
        XCTAssertEqual(ship.pullRequest?.state, "OPEN")
    }

    func testPRListPreservesBranchDraftStateAndURL() throws {
        let parsed = try DashboardClient.gitPullRequests(from: [
            "ghReady": true,
            "prs": [[
                "branch": "feature/mobile", "draft": true, "number": 77,
                "state": "open", "title": "Mobile Git rail",
                "url": "https://github.com/acme/repo/pull/77",
            ]],
        ])

        XCTAssertTrue(parsed.ghReady)
        XCTAssertEqual(parsed.pullRequests.first?.branch, "feature/mobile")
        XCTAssertEqual(parsed.pullRequests.first?.draft, true)
        XCTAssertEqual(parsed.pullRequests.first?.title, "Mobile Git rail")
    }

    func testWorktreeCreationRequiresPathBranchAndRepoRoot() throws {
        let created = try DashboardClient.gitWorktreeCreation(from: [
            "path": "/repo/.worktrees/feature", "branch": "feature", "repoRoot": "/repo",
        ])
        XCTAssertEqual(created.branch, "feature")
        XCTAssertEqual(created.repoRoot, "/repo")
        XCTAssertThrowsError(try DashboardClient.gitWorktreeCreation(from: [
            "path": "/repo/.worktrees/feature", "branch": "feature",
        ]))
    }
}
