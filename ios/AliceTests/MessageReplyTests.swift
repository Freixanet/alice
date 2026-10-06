import XCTest
@testable import Alice

@MainActor
final class MessageReplyTests: XCTestCase {
    private let quote = MessageReply(conversationID: "chat", messageID: "assistant", author: "Alice", content: "Choose A or B.")

    func testLegacyMessageAndDraftStillDecode() throws {
        let data = Data(#"{"id":"old","role":"user","content":"Hi"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Message.self, from: data).quotedReplies)
        let suite = "reply-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"text":"Unsent","mentions":[]}"#.utf8), forKey: ComposerDraftArchive.key("chat"))
        let draft = try ComposerDraftArchive(storage: defaults).load("chat")
        XCTAssertEqual(draft.text, "Unsent")
        XCTAssertTrue(draft.replies.isEmpty)
    }

    func testQuoteSurvivesDraftReloadAndCancelKeepsText() throws {
        let suite = "reply-draft-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let chat = try XCTUnwrap(store.activeID)
        let index = try XCTUnwrap(store.conversations.firstIndex { $0.id == chat })
        let assistant = Message(id: "assistant", role: .assistant, content: "Choose A or B.", createdAt: .now)
        store.conversations[index].messages = [assistant]
        store.draft = "A please"
        store.beginReply(to: assistant)
        XCTAssertEqual(store.draftReply?.messageID, assistant.id)
        store.persistConversationsImmediately()
        store.newChat()
        XCTAssertTrue(store.draftReplies.isEmpty)
        store.activeID = chat
        XCTAssertEqual(store.draftReply?.messageID, assistant.id)
        let reloaded = try ComposerDraftArchive(storage: defaults).load(chat)
        XCTAssertEqual(reloaded.replies.first?.messageID, assistant.id)
        XCTAssertEqual(reloaded.text, "A please")
        store.cancelReply()
        XCTAssertTrue(store.draftReplies.isEmpty)
        XCTAssertEqual(store.draft, "A please")
    }

    func testUserMessageHasPlainDisplayTextAndQuotedWireContext() throws {
        var user = Message(id: "user", role: .user, content: "A please", createdAt: .now)
        user.quotedReplies = [quote]
        let restored = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(user))
        XCTAssertEqual(restored.content, "A please")
        XCTAssertEqual(restored.quotedReplies, [quote])
        XCTAssertTrue(restored.outboundContent.contains("Choose A or B."))
        XCTAssertTrue(restored.outboundContent.hasSuffix("A please"))
        XCTAssertEqual(restored.outboundContent, restored.outboundContent, "Context must be deterministic for transcript matching")
    }

    func testCanonicalTranscriptKeepsQuotesWithoutDisplayingTheWireWrapper() {
        var user = Message(id: "local-user", role: .user, content: "A please", createdAt: .now)
        user.quotedReplies = [quote]
        user.remoteMatchContent = user.outboundContent
        let remote = BotChatTurn(id: "remote-user", role: .user, content: user.outboundContent, createdAt: user.createdAt)
        let merged = BotChatSync.merge([remote], into: [user])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.content, "A please")
        XCTAssertEqual(merged.first?.quotedReplies, [quote])
    }

    func testCoalescedQueuedMessagesKeepBothQuotes() {
        let other = MessageReply(conversationID: "chat", messageID: "second", author: "Alice", content: "Then choose a time.")
        var first = Message(id: "u1", role: .user, content: "A", createdAt: Date(timeIntervalSince1970: 10))
        first.quotedReplies = [quote]
        first.remoteMatchContent = first.outboundContent
        var second = Message(id: "u2", role: .user, content: "Tomorrow", createdAt: Date(timeIntervalSince1970: 11))
        second.quotedReplies = [other]
        second.remoteMatchContent = second.outboundContent
        let remote = BotChatTurn(id: "merged", role: .user, content: first.outboundContent + "\n\n" + second.outboundContent, createdAt: Date(timeIntervalSince1970: 12))
        let merged = BotChatSync.merge([remote], into: [first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.quotedReplies, [quote, other])
    }

    func testSwipeRequiresIntentAndDoesNotCompleteAReverseOrShortDrag() {
        XCTAssertTrue(MessageReplySwipe.starts(velocity: CGPoint(x: 200, y: 15)))
        XCTAssertFalse(MessageReplySwipe.starts(velocity: CGPoint(x: 20, y: 200)))
        XCTAssertFalse(MessageReplySwipe.starts(velocity: CGPoint(x: -200, y: 0)))
        XCTAssertFalse(MessageReplySwipe.completes(translation: 55))
        XCTAssertFalse(MessageReplySwipe.completes(translation: -80))
        XCTAssertTrue(MessageReplySwipe.completes(translation: 56))
    }
}
