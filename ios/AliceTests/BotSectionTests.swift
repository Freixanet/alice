import XCTest
@testable import Alice

@MainActor
final class BotSectionTests: XCTestCase {
    private func store() throws -> (AppStore, String) {
        let suite = "alice.section-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppStore(defaults: defaults), suite)
    }

    func testRenamingAHomeSectionKeepsItsBotsAndFold() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.addSection("Daily")
        store.setBotSection("radar-ia", section: "Daily")
        store.toggleSectionCollapsed("Daily")

        store.renameSection(from: "Daily", to: "  Mornings  ")
        XCTAssertEqual(store.botCustomSections, ["Mornings"])
        XCTAssertEqual(store.section(for: "radar-ia"), "Mornings")
        XCTAssertTrue(store.collapsedSections.contains("Mornings"))
        XCTAssertFalse(store.collapsedSections.contains("Daily"))
    }

    func testAHomeSectionCannotBeRenamedOntoAnotherOrUnassigned() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.addSection("Daily")
        store.addSection("Weekly")
        store.setBotSection("radar-ia", section: "Daily")

        store.renameSection(from: "Daily", to: "Weekly")
        store.renameSection(from: "Daily", to: "Unassigned")
        store.renameSection(from: "Daily", to: "   ")
        XCTAssertEqual(store.botCustomSections, ["Daily", "Weekly"])
        XCTAssertEqual(store.section(for: "radar-ia"), "Daily")
    }
}
