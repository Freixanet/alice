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

    func testReadFailureWithOlderSalvageDoesNotUnlockWrites() throws {
        let suite = "alice.persistence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let older = Conversation(
            id: "older", title: "Older", createdAt: .now, updatedAt: .now,
            messages: [Message(id: "older-message", role: .user, content: "saved", createdAt: .now)]
        )
        let salvage = try JSONEncoder().encode([older])
        defaults.set(salvage, forKey: AppStore.salvageKey)
        let index = try JSONEncoder().encode(["current"])
        let storage = RecoveryStorage(values: [ConversationArchive.indexKey: index], failsRead: true)

        let store = AppStore(defaults: defaults, conversationStorage: storage)
        XCTAssertNotNil(store.conversationsUnreadable)
        XCTAssertFalse(store.conversations.contains { $0.id == older.id })
        store.persistConversationsImmediately()
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(storage.removals, 0)
        XCTAssertEqual(storage.data(forKey: ConversationArchive.indexKey), index)
        XCTAssertEqual(defaults.data(forKey: AppStore.salvageKey), salvage)
    }

    func testMissingIndexedRecordIsNotReplacedByOlderSalvage() throws {
        let suite = "alice.persistence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let older = Conversation(
            id: "older", title: "Older", createdAt: .now, updatedAt: .now,
            messages: [Message(id: "older-message", role: .user, content: "saved", createdAt: .now)]
        )
        let salvage = try JSONEncoder().encode([older])
        defaults.set(salvage, forKey: AppStore.salvageKey)
        let storage = RecoveryStorage(values: [ConversationArchive.indexKey: try JSONEncoder().encode(["current"])])

        let store = AppStore(defaults: defaults, conversationStorage: storage)
        XCTAssertFalse(store.conversations.contains { $0.id == older.id })
        store.persistConversationsImmediately()
        let index = try XCTUnwrap(storage.data(forKey: ConversationArchive.indexKey))
        XCTAssertTrue(try JSONDecoder().decode([String].self, from: index).contains("current"))
        XCTAssertNil(storage.data(forKey: ConversationArchive.recordKey(for: "current")))
        XCTAssertEqual(defaults.data(forKey: AppStore.salvageKey), salvage)
    }

    func testUnreadableMigrationMarkerKeepsTheCurrentStoreAndBlocksWrites() throws {
        let suite = "alice.persistence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = try JSONEncoder().encode(["current"])
        let storage = RecoveryStorage(values: [ConversationArchive.indexKey: index], failsRead: true)
        let selected = ConversationArchive.storageAfterAdoption(of: storage, from: defaults)
        XCTAssertTrue(selected === storage)

        let store = AppStore(defaults: defaults, conversationStorage: selected)
        XCTAssertNotNil(store.conversationsUnreadable)
        store.persistConversationsImmediately()
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(storage.removals, 0)
        XCTAssertEqual(storage.data(forKey: ConversationArchive.indexKey), index)
        XCTAssertNil(defaults.data(forKey: ConversationArchive.indexKey))
    }
}

private final class RecoveryStorage: ConversationStorage {
    enum ReadError: Error { case inaccessible }
    private var values: [String: Data]
    private let failsRead: Bool
    private(set) var writes = 0
    private(set) var removals = 0

    init(values: [String: Data], failsRead: Bool = false) {
        self.values = values
        self.failsRead = failsRead
    }

    func data(forKey key: String) -> Data? { values[key] }
    func readData(forKey key: String) throws -> Data? {
        if failsRead { throw ReadError.inaccessible }
        return values[key]
    }
    func set(_ value: Any?, forKey key: String) {
        writes += 1
        values[key] = value as? Data
    }
    func removeObject(forKey key: String) {
        removals += 1
        values.removeValue(forKey: key)
    }
}
