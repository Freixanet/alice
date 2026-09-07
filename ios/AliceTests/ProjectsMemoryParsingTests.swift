import XCTest
@testable import Alice

final class ProjectsMemoryParsingTests: XCTestCase {
    func testNamedProjectsParseHermesFirstClassShape() throws {
        let projects = try DashboardClient.namedProjects(from: [
            "projects": [[
                "id": "p_abc12345",
                "slug": "alice-app",
                "name": "Alice App",
                "description": "Main iOS workspace",
                "color": "#8B8FF5",
                "primary_path": "/Users/marc/alice",
                "created_at": NSNumber(value: 1_788_000_000),
                "archived": false,
                "folders": [[
                    "path": "/Users/marc/alice",
                    "label": "main",
                    "is_primary": true,
                    "added_at": NSNumber(value: 1_788_000_000),
                ]],
            ]],
            "active_id": "p_abc12345",
        ])

        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.id, "p_abc12345")
        XCTAssertEqual(project.slug, "alice-app")
        XCTAssertEqual(project.name, "Alice App")
        XCTAssertEqual(project.detail, "Main iOS workspace")
        XCTAssertEqual(project.colour, "#8B8FF5")
        XCTAssertEqual(project.primaryPath, "/Users/marc/alice")
        XCTAssertFalse(project.archived)
        XCTAssertEqual(project.folders.count, 1)
        XCTAssertTrue(try XCTUnwrap(project.folders.first).isPrimary)
    }

    func testProjectTreeKeepsAuthoritativeHermesFlagsAndProfile() throws {
        let rows = try DashboardClient.projectRows(from: [
            "projects": [
                [
                    "id": "/Users/marc/repo",
                    "label": "repo",
                    "path": "/Users/marc/repo",
                    "sessionCount": NSNumber(value: 3),
                    "totalTokens": NSNumber(value: 12_345),
                    "lastActive": NSNumber(value: 1_788_000_100),
                    "isAuto": true,
                    "isNoProject": false,
                ],
                [
                    "id": "__no_project__",
                    "label": "Home",
                    "sessionCount": 1,
                    "isAuto": false,
                    "isNoProject": true,
                ],
            ],
        ], profile: "radar-ia")

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].isAuto)
        XCTAssertFalse(rows[0].isHome)
        XCTAssertEqual(rows[0].sessions, 3)
        XCTAssertEqual(rows[0].tokens, 12_345)
        XCTAssertEqual(rows[0].profile, "radar-ia")
        XCTAssertTrue(rows[1].isHome)
    }

    func testMemorySnapshotParsesRealCuratedTargets() throws {
        let snapshot = try DashboardClient.memorySnapshot(from: [
            "provider": "honcho",
            "targets": [
                [
                    "id": "user", "label": "User profile", "enabled": true,
                    "entries": ["Prefers concise answers."], "used": 24, "limit": 1375,
                ],
                [
                    "id": "memory", "label": "Agent notes", "enabled": true,
                    "entries": ["Alice is the default profile."], "used": 29, "limit": 2200,
                ],
            ],
        ], profile: "default")

        XCTAssertEqual(snapshot.profile, "default")
        XCTAssertEqual(snapshot.provider, "honcho")
        XCTAssertEqual(snapshot.targets.map(\.id), ["user", "memory"])
        XCTAssertEqual(snapshot.targets[0].entries, ["Prefers concise answers."])
        XCTAssertEqual(snapshot.targets[0].limit, 1375)
        XCTAssertEqual(snapshot.targets[1].entries, ["Alice is the default profile."])
    }

    func testProjectAndMemoryParsersRejectMissingTopLevelCollections() {
        XCTAssertThrowsError(try DashboardClient.projectRows(from: [:]))
        XCTAssertThrowsError(try DashboardClient.namedProjects(from: [:]))
        XCTAssertThrowsError(try DashboardClient.memorySnapshot(from: [:], profile: "default"))
    }
}
