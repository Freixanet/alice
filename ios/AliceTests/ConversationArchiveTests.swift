import XCTest
@testable import Alice

final class ConversationArchiveTests: XCTestCase {
    private func suite() throws -> (UserDefaults, String) {
        let name = "alice.archive-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    private func chat(_ id: String, title: String, messages: [String] = []) -> Conversation {
        let now = Date(timeIntervalSinceReferenceDate: 768_000_000)
        return Conversation(
            id: id, title: title, createdAt: now, updatedAt: now,
            messages: messages.enumerated().map { index, text in
                Message(
                    id: "\(id)-m\(index)", role: .user, content: text,
                    createdAt: now, pending: false
                )
            }
        )
    }

    func testMessageQuoteMetadataRoundTripsAndOlderMessagesStillDecode() throws {
        let older = Message(id: "old", role: .assistant, content: "Old reply", createdAt: .now)
        let oldBytes = try JSONEncoder().encode(older)
        XCTAssertNil(try JSONDecoder().decode(Message.self, from: oldBytes).quote)

        let quote = Message.Quote(messageID: "answer", author: "Alice", text: "A short excerpt")
        let user = Message(id: "user", role: .user, content: "Tell me more", createdAt: .now, quote: quote)
        let bytes = try JSONEncoder().encode(user)
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: bytes).quote, quote)
    }

    func testQuoteExcerptCollapsesLinesAndTruncatesCleanly() {
        XCTAssertEqual(Message.quoteExcerpt("first line\nsecond line"), "first line second line")
        XCTAssertEqual(Message.quoteExcerpt("123456789", limit: 5), "1234…")
    }

    func testALegacyBlobStillLoads() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let saved = [chat("c1", title: "Radar", messages: ["informe"])]
        defaults.set(try JSONEncoder().encode(saved), forKey: ConversationArchive.blobKey)

        guard case let .available(loaded) = ConversationArchive.load(from: defaults) else {
            return XCTFail("expected the blob to load")
        }
        XCTAssertEqual(loaded.source, .blob)
        XCTAssertEqual(loaded.conversations.map(\.id), ["c1"])
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.content), ["informe"])
    }

    func testASaveWritesOneRecordPerConversationAndDropsTheBlob() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let radar = chat("c1", title: "Radar", messages: ["informe"])
        let home = chat("c2", title: "Home", messages: ["hola"])
        defaults.set(
            try JSONEncoder().encode([radar, home]),
            forKey: ConversationArchive.blobKey
        )
        guard case let .available(loaded) = ConversationArchive.load(from: defaults) else {
            return XCTFail("expected the blob to load")
        }
        let prepared = try ConversationArchive.prepare(
            .init(
                conversations: loaded.conversations,
                fingerprints: [:],
                persistedIDs: [],
                protectedIDs: []
            )
        )
        ConversationArchive.apply(prepared, to: defaults)

        XCTAssertNil(defaults.data(forKey: ConversationArchive.blobKey))
        XCTAssertNotNil(defaults.data(forKey: ConversationArchive.indexKey))
        XCTAssertNotNil(defaults.data(forKey: ConversationArchive.recordKey(for: "c1")))
        XCTAssertNotNil(defaults.data(forKey: ConversationArchive.recordKey(for: "c2")))

        guard case let .available(again) = ConversationArchive.load(from: defaults) else {
            return XCTFail("expected the split archive to load")
        }
        XCTAssertEqual(again.source, .split)
        XCTAssertEqual(again.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(again.conversations[0].messages.map(\.content), ["informe"])
    }

    func testAnUnchangedConversationIsNotEncodedAgain() throws {
        let radar = chat("c1", title: "Radar", messages: ["informe"])
        let home = chat("c2", title: "Home", messages: ["hola"])
        let first = try ConversationArchive.prepare(
            .init(
                conversations: [radar, home],
                fingerprints: [:],
                persistedIDs: [],
                protectedIDs: []
            )
        )
        XCTAssertEqual(first.records.count, 2)

        var edited = home
        edited.title = "Casa"
        let second = try ConversationArchive.prepare(
            .init(
                conversations: [radar, edited],
                fingerprints: first.fingerprints,
                persistedIDs: first.persistedIDs,
                protectedIDs: []
            )
        )
        XCTAssertEqual(second.records.map(\.key), [ConversationArchive.recordKey(for: "c2")])
    }

    func testDeletingAConversationRemovesItsRecordAndLeavesTheOther() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let radar = chat("c1", title: "Radar")
        let home = chat("c2", title: "Home")
        let first = try ConversationArchive.prepare(
            .init(
                conversations: [radar, home],
                fingerprints: [:],
                persistedIDs: [],
                protectedIDs: []
            )
        )
        ConversationArchive.apply(first, to: defaults)

        let second = try ConversationArchive.prepare(
            .init(
                conversations: [home],
                fingerprints: first.fingerprints,
                persistedIDs: first.persistedIDs,
                protectedIDs: []
            )
        )
        ConversationArchive.apply(second, to: defaults)

        XCTAssertNil(defaults.data(forKey: ConversationArchive.recordKey(for: "c1")))
        XCTAssertNotNil(defaults.data(forKey: ConversationArchive.recordKey(for: "c2")))
        guard case let .available(loaded) = ConversationArchive.load(from: defaults) else {
            return XCTFail("expected the remaining chat")
        }
        XCTAssertEqual(loaded.conversations.map(\.id), ["c2"])
    }

    func testOneCorruptRecordDoesNotDropTheOthers() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let radar = chat("c1", title: "Radar", messages: ["informe"])
        let home = chat("c2", title: "Home", messages: ["hola"])
        ConversationArchive.apply(
            try ConversationArchive.prepare(
                .init(
                    conversations: [radar, home],
                    fingerprints: [:],
                    persistedIDs: [],
                    protectedIDs: []
                )
            ),
            to: defaults
        )
        let corrupt = Data("{ this is not a conversation".utf8)
        defaults.set(corrupt, forKey: ConversationArchive.recordKey(for: "c1"))

        guard case let .available(loaded) = ConversationArchive.load(from: defaults) else {
            return XCTFail("the readable chat must still load")
        }
        XCTAssertEqual(loaded.conversations.map(\.id), ["c2"])
        XCTAssertEqual(loaded.skipped.map(\.id), ["c1"])
        XCTAssertEqual(loaded.skipped.first?.bytes, corrupt)
        XCTAssertFalse(loaded.skipped[0].reason.contains("this is not a conversation"))
    }

    func testAnUnreadableBlobIsNotAnEmptyHistory() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let corrupt = Data("{ this is not an archive".utf8)
        defaults.set(corrupt, forKey: ConversationArchive.blobKey)

        switch ConversationArchive.load(from: defaults) {
        case .unreadable(let reason, let bytes):
            XCTAssertEqual(bytes, corrupt)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason.contains("this is not an archive"))
        default:
            XCTFail("a corrupt blob must block writing, not look empty")
        }
    }

    func testReadFailureDoesNotFallBackToAnOlderBlob() throws {
        let conversation = chat("c1", title: "Current")
        let recordKey = ConversationArchive.recordKey(for: conversation.id)
        let storage = ReadFailingStorage(
            values: [
                ConversationArchive.indexKey: try JSONEncoder().encode([conversation.id]),
                recordKey: try JSONEncoder().encode(conversation),
                ConversationArchive.blobKey: try JSONEncoder().encode([chat("old", title: "Older")])
            ],
            failingReads: [recordKey]
        )

        switch ConversationArchive.load(from: storage) {
        case let .unreadable(reason, bytes):
            XCTAssertTrue(reason.contains("storageReadFailed"))
            XCTAssertTrue(bytes.isEmpty)
        default:
            XCTFail("an I/O error must preserve the current archive instead of loading stale data")
        }
    }

    func testMissingIndexedRecordDoesNotFallBackToAnOlderBlob() throws {
        let storage = ReadFailingStorage(
            values: [
                ConversationArchive.indexKey: try JSONEncoder().encode(["missing"]),
                ConversationArchive.blobKey: try JSONEncoder().encode([chat("old", title: "Older")])
            ],
            failingReads: []
        )

        guard case let .available(loaded) = ConversationArchive.load(from: storage) else {
            return XCTFail("a missing record must not restore an older conversation")
        }
        XCTAssertTrue(loaded.conversations.isEmpty)
        XCTAssertEqual(loaded.skipped.map(\.id), ["missing"])
        XCTAssertEqual(loaded.skipped.first?.reason, "indexed record is missing")
    }

    func testEmptyIndexCannotLookLikeANewInstall() {
        let storage = ReadFailingStorage(
            values: [ConversationArchive.indexKey: Data()],
            failingReads: []
        )

        guard case let .unreadable(reason, bytes) = ConversationArchive.load(from: storage) else {
            return XCTFail("an empty index must block replacement")
        }
        XCTAssertEqual(reason, "emptyIndex")
        XCTAssertTrue(bytes.isEmpty)
    }
}

private final class ReadFailingStorage: ConversationStorage {
    enum ReadError: Error { case inaccessible }

    private var values: [String: Data]
    private let failingReads: Set<String>

    init(values: [String: Data], failingReads: Set<String>) {
        self.values = values
        self.failingReads = failingReads
    }

    func data(forKey key: String) -> Data? { values[key] }

    func readData(forKey key: String) throws -> Data? {
        if failingReads.contains(key) { throw ReadError.inaccessible }
        return values[key]
    }

    func set(_ value: Any?, forKey key: String) { values[key] = value as? Data }
    func removeObject(forKey key: String) { values[key] = nil }
}
