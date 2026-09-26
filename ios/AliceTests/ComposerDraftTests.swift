import XCTest
@testable import Alice

@MainActor
final class ComposerDraftTests: XCTestCase {
    private func fixture(_ check: (AppStore, UserDefaults) throws -> Void) throws {
        let suite = "alice.drafts-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(AppStore(defaults: defaults), defaults)
    }

    private var file: Attachment {
        Attachment(id: "file-1", name: "notes.txt", mime: "text/plain", kind: .file, data: Data("Keep me".utf8))
    }

    func testNewChatStartsEmptyAndReturningRestoresTextMentionsAndAttachments() throws {
        try fixture { store, _ in
            let original = try XCTUnwrap(store.activeID)
            store.draft = "Forge, help me"
            let mention = DraftMention(display: "Forge", slug: "forja", location: 0)
            store.draftMentions = [mention]
            store.draftAttachments = [file]
            store.newChat()
            XCTAssertEqual(store.draft, "")
            XCTAssertTrue(store.draftMentions.isEmpty)
            XCTAssertTrue(store.draftAttachments.isEmpty)
            // Search, notifications and agent navigation also set activeID.
            store.activeID = original
            XCTAssertEqual(store.draft, "Forge, help me")
            XCTAssertEqual(store.draftMentions, [mention])
            XCTAssertEqual(store.draftAttachments, [file])
        }
    }

    func testForegroundDraftSurvivesClosingAndReopeningTheApp() throws {
        try fixture { store, defaults in
            let id = try XCTUnwrap(store.activeID)
            store.draft = "Forge, help me"
            let mention = DraftMention(display: "Forge", slug: "forja", location: 0)
            store.draftMentions = [mention]
            store.draftAttachments = [file]
            store.persistConversationsImmediately()
            let reopened = AppStore(defaults: defaults)
            reopened.openChat(id)
            XCTAssertEqual(reopened.draft, "Forge, help me")
            XCTAssertEqual(reopened.draftMentions, [mention])
            XCTAssertEqual(reopened.draftAttachments, [file])
        }
    }

    func testADeletedChatDoesNotDonateItsDraftToTheNextChat() throws {
        try fixture { store, defaults in
            let old = try XCTUnwrap(store.activeID)
            store.draft = "Private to this chat"
            store.draftAttachments = [file]
            store.persistConversationsImmediately()
            store.delete(old)
            XCTAssertEqual(store.draft, "")
            XCTAssertTrue(store.draftAttachments.isEmpty)
            XCTAssertNil(defaults.data(forKey: ComposerDraftArchive.key(old)))
        }
    }

    func testOpeningAnUnknownChatDoesNotDiscardTheCurrentDraft() throws {
        try fixture { store, _ in
            let id = store.activeID
            store.draft = "Unsent"
            store.openChat("missing")
            XCTAssertEqual(store.activeID, id)
            XCTAssertEqual(store.draft, "Unsent")
        }
    }

    func testCancellingAnEditRestoresTheUnsentWork() throws {
        try fixture { store, _ in
            let id = try XCTUnwrap(store.activeID)
            let index = try XCTUnwrap(store.conversations.firstIndex { $0.id == id })
            let message = Message(id: "sent", role: .user, content: "Original message", createdAt: Date())
            store.conversations[index].messages = [message]
            store.draft = "My next message"
            store.draftAttachments = [file]
            store.beginEditing(message)
            XCTAssertEqual(store.draft, "Original message")
            XCTAssertTrue(store.draftAttachments.isEmpty)
            store.cancelEditing()
            XCTAssertEqual(store.draft, "My next message")
            XCTAssertEqual(store.draftAttachments, [file])
        }
    }

    func testALatePhotoImportStaysWithItsOriginalConversation() throws {
        try fixture { store, _ in
            let old = try XCTUnwrap(store.activeID)
            store.newChat()
            store.draft = "A different task"
            store.appendDraftAttachments([file], to: old)
            XCTAssertTrue(store.draftAttachments.isEmpty)
            XCTAssertEqual(store.draft, "A different task")
            store.openChat(old)
            XCTAssertEqual(store.draftAttachments, [file])
        }
    }

    func testFailedQuestionAnswerReturnsToItsOwnChatWithoutOverwritingNewText() throws {
        try fixture { store, _ in
            let old = try XCTUnwrap(store.activeID)
            store.newChat()
            store.restoreUnsentText("My answer", to: old)
            XCTAssertEqual(store.draft, "")
            store.openChat(old)
            XCTAssertEqual(store.draft, "My answer")
            store.draft = "Changed my mind"
            store.restoreUnsentText("Old answer", to: old)
            XCTAssertEqual(store.draft, "Changed my mind")
        }
    }

    func testUnreadableDraftIsPreservedInsteadOfOverwritten() throws {
        try fixture { _, defaults in
            let key = ComposerDraftArchive.key("broken")
            let bytes = Data("broken-json".utf8)
            defaults.set(bytes, forKey: key)
            let archive = ComposerDraftArchive(storage: defaults)
            XCTAssertThrowsError(try archive.load("broken"))
            XCTAssertThrowsError(try archive.save(ComposerDraft(text: "Replacement"), for: "broken"))
            XCTAssertEqual(defaults.data(forKey: key), bytes)
        }
    }

    func testTypingDoesNotRewriteAttachmentBytes() throws {
        let storage = DraftCountingStorage()
        let archive = ComposerDraftArchive(storage: storage)
        let key = ComposerDraftArchive.key("chat") + ".attachments"
        try archive.save(ComposerDraft(text: "One", attachments: [file]), for: "chat")
        try archive.save(ComposerDraft(text: "One more word", attachments: [file]), for: "chat")
        XCTAssertEqual(storage.writes[key], 1)
        let reopened = ComposerDraftArchive(storage: storage)
        XCTAssertEqual(try reopened.load("chat").attachments, [file])
        XCTAssertEqual(try reopened.load("chat").text, "One more word")
    }

    func testAStorageFailureIsNotReportedAsASavedDraft() {
        let storage = DraftCountingStorage()
        storage.rejectWrites = true
        XCTAssertThrowsError(try ComposerDraftArchive(storage: storage).save(ComposerDraft(text: "Keep me"), for: "chat"))
    }

    func testLegacyTextDraftMigratesAndDoesNotReturnAfterBeingCleared() throws {
        try fixture { store, defaults in
            let id = try XCTUnwrap(store.activeID)
            store.persistConversationsImmediately()
            defaults.removeObject(forKey: ComposerDraftArchive.key(id))
            defaults.set([id: "Old draft"], forKey: "alice.chat.unsentDrafts")
            let migrated = AppStore(defaults: defaults)
            migrated.openChat(id)
            XCTAssertEqual(migrated.draft, "Old draft")
            migrated.draft = ""
            migrated.persistConversationsImmediately()
            let reopened = AppStore(defaults: defaults)
            reopened.openChat(id)
            XCTAssertEqual(reopened.draft, "")
        }
    }

    func testRecentsAttentionUsesLiveMessagesEvenWhenShelfMembershipIsUnchanged() throws {
        try fixture { store, _ in
            let snapshot = try XCTUnwrap(store.recentConversations.first)
            let index = try XCTUnwrap(store.conversations.firstIndex { $0.id == snapshot.id })
            let approval = Message.Approval(runID: "run", title: "Approve", detail: nil, command: nil, choices: [.once])
            store.conversations[index].messages = [Message(
                id: "reply", role: .assistant, content: "", createdAt: Date(), approval: approval
            )]
            XCTAssertEqual(store.attention(for: snapshot), .needsYou)
            store.conversations[index].messages[0].approval = nil
            XCTAssertNil(store.attention(for: snapshot))
        }
    }
}

private final class DraftCountingStorage: ConversationStorage {
    var values: [String: Data] = [:]
    var writes: [String: Int] = [:]
    var rejectWrites = false
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        guard !rejectWrites else { return }
        values[key] = value as? Data
        writes[key, default: 0] += 1
    }
    func removeObject(forKey key: String) { values[key] = nil }
}
