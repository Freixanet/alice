import XCTest
@testable import Alice

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    func testRenameAndPinSurviveReopeningWithoutSendingAnotherMessage() throws {
        let suite = "alice.persistence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let id = try XCTUnwrap(store.conversations.first?.id)
        store.rename(id, to: "  My research  ")
        let renamed = AppStore(defaults: defaults)
        XCTAssertEqual(renamed.conversations.first(where: { $0.id == id })?.title, "My research")
        store.togglePin(id)
        let pinned = AppStore(defaults: defaults)
        XCTAssertEqual(pinned.conversations.first(where: { $0.id == id })?.pinned, true)
        store.togglePin(id)
        let unpinned = AppStore(defaults: defaults)
        XCTAssertEqual(unpinned.conversations.first(where: { $0.id == id })?.pinned, false)
    }

    func testEmptyRenameKeepsTheExistingTitle() throws {
        let suite = "alice.persistence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let id = try XCTUnwrap(store.conversations.first?.id)
        store.rename(id, to: "Saved title")
        store.rename(id, to: " \n ")
        XCTAssertEqual(AppStore(defaults: defaults).conversations.first(where: { $0.id == id })?.title, "Saved title")
    }
}
