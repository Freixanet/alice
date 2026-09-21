import XCTest
@testable import Alice

/// Conversations moved out of `UserDefaults` into files. The move must never
/// lose a byte, and a save with nothing new must not write.
final class ConversationStorageTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "alice-storage-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        suiteName = "alice.storage-test.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func chat(_ id: String, _ text: String) -> Conversation {
        let now = Date(timeIntervalSinceReferenceDate: 768_000_000)
        return Conversation(
            id: id, title: id, createdAt: now, updatedAt: now,
            messages: [Message(id: "\(id)-m", role: .user, content: text, createdAt: now, pending: false)]
        )
    }

    private func save(_ chats: [Conversation], to storage: ConversationStorage) throws {
        let prepared = try ConversationArchive.prepare(.init(
            conversations: chats, fingerprints: [:], persistedIDs: [], protectedIDs: []
        ))
        ConversationArchive.apply(prepared, to: storage)
    }

    func testFilesKeepWhatIsWrittenAndForgetWhatIsRemoved() {
        let files = FileConversationStorage(directory: directory)
        files.set(Data("uno".utf8), forKey: "alice.conversation.a")
        XCTAssertEqual(files.data(forKey: "alice.conversation.a"), Data("uno".utf8))
        files.removeObject(forKey: "alice.conversation.a")
        XCTAssertNil(files.data(forKey: "alice.conversation.a"))
        XCTAssertNil(files.takeFailure())
    }

    func testTheMoveCarriesEveryRecordAndEmptiesTheOldStorage() throws {
        try save([chat("c1", "hola"), chat("c2", "adiós")], to: defaults)
        let before = ConversationArchive.load(from: defaults)

        let files = FileConversationStorage(directory: directory)
        XCTAssertTrue(ConversationArchive.adopt(files, from: defaults))

        XCTAssertEqual(ConversationArchive.load(from: files), before)
        XCTAssertNil(defaults.data(forKey: ConversationArchive.indexKey))
        XCTAssertNil(defaults.data(forKey: ConversationArchive.recordKey(for: "c1")))
    }

    func testARecordThisBuildCannotReadMovesByteForByte() throws {
        try save([chat("c1", "hola")], to: defaults)
        let unreadable = Data("{ not a conversation".utf8)
        defaults.set(unreadable, forKey: ConversationArchive.recordKey(for: "c1"))

        let files = FileConversationStorage(directory: directory)
        XCTAssertTrue(ConversationArchive.adopt(files, from: defaults))
        XCTAssertEqual(files.data(forKey: ConversationArchive.recordKey(for: "c1")), unreadable)
    }

    func testAnUnreadableIndexStaysWhereItIs() {
        let broken = Data("not an index".utf8)
        defaults.set(broken, forKey: ConversationArchive.indexKey)

        let files = FileConversationStorage(directory: directory)
        XCTAssertFalse(ConversationArchive.adopt(files, from: defaults))
        XCTAssertEqual(defaults.data(forKey: ConversationArchive.indexKey), broken)
    }

    func testAMovedArchiveIsNotMovedAgainAndLeftoversGo() throws {
        let files = FileConversationStorage(directory: directory)
        try save([chat("c1", "hola")], to: defaults)
        XCTAssertTrue(ConversationArchive.adopt(files, from: defaults))
        try save([chat("c1", "nuevo")], to: files)

        // An interruption after the marker left the old copy behind.
        try save([chat("c1", "viejo")], to: defaults)
        XCTAssertTrue(ConversationArchive.adopt(files, from: defaults))

        guard case let .available(loaded) = ConversationArchive.load(from: files) else {
            return XCTFail("expected the files to load")
        }
        XCTAssertEqual(loaded.conversations.first?.messages.first?.content, "nuevo")
        XCTAssertNil(defaults.data(forKey: ConversationArchive.indexKey))
    }

    func testAFreshInstallStartsInFiles() {
        let files = FileConversationStorage(directory: directory)
        XCTAssertTrue(ConversationArchive.adopt(files, from: defaults))
        XCTAssertEqual(ConversationArchive.load(from: files), .empty)
    }

    func testASaveWithNothingNewWritesNothing() throws {
        let storage = CountingStorage()
        let chats = [chat("c1", "hola")]
        let first = try ConversationArchive.prepare(.init(
            conversations: chats, fingerprints: [:], persistedIDs: [], protectedIDs: []
        ))
        ConversationArchive.apply(first, to: storage)
        storage.writes = 0

        let again = try ConversationArchive.prepare(.init(
            conversations: chats, fingerprints: first.fingerprints,
            persistedIDs: first.persistedIDs, protectedIDs: []
        ))
        ConversationArchive.apply(again, to: storage)
        XCTAssertEqual(storage.writes, 0)
    }
}

private final class CountingStorage: ConversationStorage {
    var values: [String: Data] = [:]
    var writes = 0

    func data(forKey key: String) -> Data? { values[key] }

    func set(_ value: Any?, forKey key: String) {
        writes += 1
        values[key] = value as? Data
    }

    func removeObject(forKey key: String) {
        writes += 1
        values[key] = nil
    }
}
