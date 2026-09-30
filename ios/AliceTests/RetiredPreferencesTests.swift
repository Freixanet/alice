import XCTest
@testable import Alice

/// Settings no build reads leave preferences only once their bytes are safe in a file
/// (`RetiredPreferences`), and Developer › Storage names what makes settings big (`StorageUsage`).
final class RetiredPreferencesTests: XCTestCase {
    private var folder: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appending(path: "retired-\(UUID().uuidString)")
        suite = "alice.tests.retired.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    func testARetiredKeyIsKeptInAFileAndThenRemoved() throws {
        let archive = Data("{\"interests\":[\"Ciencia\"],\"saved\":[\"post-1\"]}".utf8)
        defaults.set(archive, forKey: "alice.newsFeed.v1")
        defaults.set("dark", forKey: "alice.theme")

        let moved = RetiredPreferences.moveToFiles(defaults, folder: folder)

        XCTAssertEqual(moved, ["alice.newsFeed.v1"])
        XCTAssertNil(defaults.object(forKey: "alice.newsFeed.v1"))
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "alice.newsFeed.v1.data")), archive)
        XCTAssertEqual(defaults.string(forKey: "alice.theme"), "dark", "only retired keys move")
    }

    func testMovingAgainChangesNothing() throws {
        let archive = Data("old".utf8)
        defaults.set(archive, forKey: "alice.newsFeed.v1")
        RetiredPreferences.moveToFiles(defaults, folder: folder)

        XCTAssertEqual(RetiredPreferences.moveToFiles(defaults, folder: folder), [])
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "alice.newsFeed.v1.data")), archive)
    }

    func testWithoutAPlaceToWriteTheKeyStays() {
        defaults.set(Data("old".utf8), forKey: "alice.newsFeed.v1")
        XCTAssertEqual(RetiredPreferences.moveToFiles(defaults, folder: nil), [])
        XCTAssertNotNil(defaults.data(forKey: "alice.newsFeed.v1"))
    }

    func testStorageNamesTheLargestSettingsFirst() {
        defaults.set(Data(count: 40_000), forKey: "big")
        defaults.set(Data(count: 4_000), forKey: "medium")
        defaults.set(Data(count: 400), forKey: "small")
        defaults.set(true, forKey: "tiny")

        let usage = StorageUsage.measure(defaults: defaults, domain: suite, conversations: nil)

        XCTAssertEqual(usage.largestKeys.map(\.key), ["big", "medium", "small"])
        XCTAssertGreaterThan(usage.settings, 44_000)
        XCTAssertEqual(usage.conversations, 0)
    }
}
