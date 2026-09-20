import XCTest
@testable import Alice

/// Reading archives written by builds that came before.
///
/// The regression these exist for: adding `var localOnly: Bool = false` to
/// `Message` made the synthesized decoder demand a key no previous build had
/// written. A default on a non-optional property does not make the decoder
/// tolerant — it still throws `keyNotFound`. The loader swallowed that with
/// `try?`, started empty, and the next save wrote the empty result over every
/// conversation on the phone.
final class ConversationMigrationTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// An archive exactly as the shipping build before this change wrote one:
    /// no `remoteID`, no `localOnly`, no `hermesSessionID`.
    private static let oldArchive = """
    [
      {"id":"c1","title":"New chat","createdAt":768000000,"updatedAt":768000300,
       "pinned":false,"isChannel":false,"channelBots":[],
       "messages":[
         {"id":"m1","role":"user","content":"¿qué tal?","createdAt":768000000,
          "pending":false,"tools":[],"incomplete":false,"attachments":[]},
         {"id":"m2","role":"assistant","content":"bien","createdAt":768000060,
          "pending":false,"tools":[],"incomplete":false,"attachments":[]}
       ]},
      {"id":"c2","title":"Radar IA","createdAt":768000400,"updatedAt":768000500,
       "pinned":true,"botName":"radar-ia","isChannel":false,"channelBots":[],
       "messages":[
         {"id":"m3","role":"user","content":"informe","createdAt":768000400,
          "pending":false,"tools":[],"incomplete":false,"attachments":[],
          "botName":"radar-ia"}
       ]},
      {"id":"c3","title":"Chollometro","createdAt":768000600,"updatedAt":768000600,
       "pinned":false,"botName":"chollometro","isChannel":false,"channelBots":[],
       "messages":[]}
    ]
    """

    // MARK: - A. A message from before the new fields

    func testAnOldMessageDecodes() throws {
        let message = try decode(Message.self, """
        {"id":"m1","role":"assistant","content":"hola","createdAt":768000000,
         "pending":false,"tools":[],"incomplete":false,"attachments":[]}
        """)

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.content, "hola")
        XCTAssertNil(message.remoteID)
        XCTAssertFalse(message.localOnly, "a missing key must fall back, not throw")
        XCTAssertFalse(message.interim, "a missing interim key must fall back, not throw")
    }

    /// The exact failure that erased the phone, as a standing guard.
    func testAMessageWithoutLocalOnlyDoesNotThrowKeyNotFound() {
        XCTAssertNoThrow(
            try decode(Message.self, """
            {"id":"m","role":"user","content":"x","createdAt":1}
            """),
            "a missing localOnly key is what destroyed the archive"
        )
    }

    // MARK: - B. A conversation from before hermesSessionID

    func testAnOldConversationDecodes() throws {
        let chat = try decode(Conversation.self, """
        {"id":"c1","title":"Radar IA","createdAt":768000000,"updatedAt":768000100,
         "botName":"radar-ia","messages":[]}
        """)

        XCTAssertEqual(chat.botName, "radar-ia")
        XCTAssertNil(chat.hermesSessionID)
        XCTAssertFalse(chat.pinned)
    }

    // MARK: - C. A whole archive survives intact

    func testTheWholeOldArchiveLoadsWithNothingLost() throws {
        let chats = try decode([Conversation].self, Self.oldArchive)

        XCTAssertEqual(chats.count, 3)
        XCTAssertEqual(chats.reduce(0) { $0 + $1.messages.count }, 3)
        XCTAssertEqual(chats.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(chats.map(\.title), ["New chat", "Radar IA", "Chollometro"])
        XCTAssertEqual(chats[1].messages.map(\.content), ["informe"])
        XCTAssertEqual(chats[0].messages[1].createdAt,
                       Date(timeIntervalSinceReferenceDate: 768000060))
        XCTAssertTrue(chats[1].pinned)
        XCTAssertEqual(chats.compactMap(\.botName), ["radar-ia", "chollometro"])
        // New fields default, and nothing else moved.
        XCTAssertTrue(chats.allSatisfy { $0.hermesSessionID == nil })
        XCTAssertTrue(chats.flatMap(\.messages).allSatisfy { !$0.localOnly })
    }

    // MARK: - E. Round trip

    func testAnOldArchiveSurvivesReEncoding() throws {
        let first = try decode([Conversation].self, Self.oldArchive)
        let data = try JSONEncoder().encode(first)
        let second = try JSONDecoder().decode([Conversation].self, from: data)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.flatMap(\.messages).map(\.id),
                       second.flatMap(\.messages).map(\.id))
        XCTAssertEqual(first.flatMap(\.messages).map(\.content),
                       second.flatMap(\.messages).map(\.content))
        XCTAssertEqual(first.flatMap(\.messages).map(\.createdAt),
                       second.flatMap(\.messages).map(\.createdAt))
    }

    // MARK: - F. A bot chat survives migration before any remote merge

    func testAnOldBotChatKeepsItsHistoryBeforeAnyRemoteMerge() throws {
        let chats = try decode([Conversation].self, Self.oldArchive)
        let radar = try XCTUnwrap(chats.first { $0.botName == "radar-ia" })

        XCTAssertNil(radar.hermesSessionID, "not yet attached to a Hermes session")
        XCTAssertEqual(radar.messages.map(\.content), ["informe"])
        // Merging an empty remote transcript must not drop it either; it is
        // marked as history the agent has no record of.
        let merged = BotChatSync.merge([], into: radar.messages)
        XCTAssertEqual(merged.map(\.content), ["informe"])
        XCTAssertTrue(merged.allSatisfy(\.localOnly))
    }

    // MARK: - D. An archive that truly cannot be read

    func testAnUnreadableArchiveIsNotAnEmptyHistory() {
        // Not a decode failure over a missing new key — that can no longer
        // happen — but a genuinely corrupt one.
        let corrupt = Data("{ this is not an archive".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([Conversation].self, from: corrupt))

        // What matters is what the app is allowed to conclude from it: a
        // description with no archive contents in it.
        do {
            _ = try JSONDecoder().decode([Conversation].self, from: corrupt)
            XCTFail("that archive is not decodable")
        } catch {
            let description = AppStore.describe(error)
            XCTAssertFalse(description.isEmpty)
            XCTAssertFalse(
                description.contains("this is not an archive"),
                "a diagnostic must not carry the archive's contents"
            )
        }
    }

    /// The salvage key is a distinct place, so the unreadable bytes are never
    /// the ones being written over.
    func testTheSalvageKeyIsSeparateFromTheLiveArchive() {
        XCTAssertNotEqual(AppStore.salvageKey, "alice.conversations")
        XCTAssertTrue(AppStore.salvageKey.hasPrefix("alice.conversations"))
    }
}
