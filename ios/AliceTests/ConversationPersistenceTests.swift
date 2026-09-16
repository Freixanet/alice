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
        store.persistConversationsImmediately()
        let renamed = AppStore(defaults: defaults)
        XCTAssertEqual(renamed.conversations.first(where: { $0.id == id })?.title, "My research")
        store.togglePin(id)
        store.persistConversationsImmediately()
        let pinned = AppStore(defaults: defaults)
        XCTAssertEqual(pinned.conversations.first(where: { $0.id == id })?.pinned, true)
        store.togglePin(id)
        store.persistConversationsImmediately()
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
        store.persistConversationsImmediately()
        store.rename(id, to: " \n ")
        store.persistConversationsImmediately()
        XCTAssertEqual(AppStore(defaults: defaults).conversations.first(where: { $0.id == id })?.title, "Saved title")
    }

    func testALegacyBlobOpensAndTheNextSaveStoresEachChatOnItsOwn() throws {
        let suite = "alice.persistence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chat = Conversation.blank(title: "Radar")
        defaults.set(try JSONEncoder().encode([chat]), forKey: ConversationArchive.blobKey)

        let store = AppStore(defaults: defaults)
        XCTAssertEqual(store.conversations.first?.id, chat.id)
        XCTAssertEqual(store.conversations.first?.title, "Radar")
        store.persistConversationsImmediately()

        XCTAssertNil(defaults.data(forKey: ConversationArchive.blobKey))
        XCTAssertNotNil(defaults.data(forKey: ConversationArchive.recordKey(for: chat.id)))
        XCTAssertEqual(AppStore(defaults: defaults).conversations.first?.title, "Radar")
    }

    func testAnUnreadableArchiveIsLeftUntouched() throws {
        let suite = "alice.persistence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("{ this is not an archive".utf8)
        defaults.set(corrupt, forKey: ConversationArchive.blobKey)

        let store = AppStore(defaults: defaults)
        XCTAssertNotNil(store.conversationsUnreadable)
        store.persistConversationsImmediately()
        XCTAssertEqual(defaults.data(forKey: ConversationArchive.blobKey), corrupt)
        XCTAssertEqual(defaults.data(forKey: AppStore.salvageKey), corrupt)
        XCTAssertNil(defaults.data(forKey: ConversationArchive.indexKey))
    }
}
