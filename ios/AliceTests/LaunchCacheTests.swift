import XCTest
@testable import Alice

/// The last lists seen, for screens to open on (`LaunchCache`): tied to one Mac, a week at most.
final class LaunchCacheTests: XCTestCase {
    private var folder: URL!
    private let scope = LaunchCache.scope(dashboard: "https://mac.local:9119", user: "marc")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appending(path: "launch-\(UUID().uuidString)")
    }

    override func tearDown() {
        LaunchCache.clear(in: folder)
    }

    private func routine(_ id: String) -> JobRow {
        JobRow(id: id, name: "Buenos días", prompt: "", schedule: "30 7 * * *", enabled: true,
               lastStatus: "ok", lastError: nil, lastRun: nil, nextRun: nil, profile: "default")
    }

    func testARoundTrip() {
        LaunchCache.write(.routines, [routine("a"), routine("b")], scope: scope, now: now, in: folder)
        let read = LaunchCache.read(.routines, as: [JobRow].self, scope: scope, now: now, in: folder)
        XCTAssertEqual(read?.map(\.id), ["a", "b"])
    }

    func testAnotherMacsListIsNotShown() {
        LaunchCache.write(.routines, [routine("a")], scope: scope, now: now, in: folder)
        let other = LaunchCache.scope(dashboard: "https://other.local:9119", user: "marc")
        XCTAssertNil(LaunchCache.read(.routines, as: [JobRow].self, scope: other, now: now, in: folder))
    }

    func testAListOlderThanAWeekIsIgnored() {
        LaunchCache.write(.routines, [routine("a")], scope: scope, now: now, in: folder)
        let later = now.addingTimeInterval(LaunchCache.lifetime + 1)
        XCTAssertNil(LaunchCache.read(.routines, as: [JobRow].self, scope: scope, now: later, in: folder))
    }

    func testClearForgetsEverything() {
        LaunchCache.write(.models, [HermesClient.ModelOption(id: "m", label: "M")], scope: scope, now: now, in: folder)
        LaunchCache.clear(in: folder)
        XCTAssertNil(LaunchCache.read(.models, as: [HermesClient.ModelOption].self, scope: scope, now: now, in: folder))
    }

    func testAnErrandSurvivesTheTrip() throws {
        let row: [String: Any] = [
            "id": "a1b2c3d4e5", "title": "Comprar creatina", "request": "Compra creatina", "site": "hsnstore.com",
            "status": "needs_approval", "started_at": 1_790_000_000.0, "updated_at": 1_790_000_090.0,
            "checkout": ["id": "c1", "status": "pending", "merchant": "HSN", "site": "hsnstore.com",
                         "total": "27,98 €", "items": [["name": "Creatina", "qty": 1, "price": "27,98 €"]]],
            "steps": [["text": "Abrir HSN", "url": "https://www.hsnstore.com", "at": 1_790_000_010.0]],
        ]
        let errand = try XCTUnwrap(Errand.parse(row))
        LaunchCache.write(.errands, [errand], scope: scope, now: now, in: folder)
        let read = try XCTUnwrap(LaunchCache.read(.errands, as: [Errand].self, scope: scope, now: now, in: folder))
        XCTAssertEqual(read, [errand])
    }

    func testAnUnreadableFileIsNothing() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: "artifacts.json"))
        XCTAssertNil(LaunchCache.read(.artifacts, as: [Artifact].self, scope: scope, now: now, in: folder))
    }
}
