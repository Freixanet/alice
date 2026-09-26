import XCTest
@testable import Alice

final class AgentTaskSessionTests: XCTestCase {
    private actor Hermes: HermesRPCTransport {
        var calls: [(String, JSONObject)] = []
        let missing: Bool
        let offline: Bool
        init(missing: Bool = false, offline: Bool = false) {
            self.missing = missing
            self.offline = offline
        }
        func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
            calls.append((method, params))
            if method == "session.resume" {
                if offline { throw HermesRPCClient.Failure(reason: "Offline") }
                if missing { throw HermesRPCClient.Failure(reason: "session not found") }
            }
            return JSONObject([
                "session_id": "task-live", "stored_session_id": "task-stored",
                "info": ["model": "profile-model", "provider": "profile-provider"],
            ])
        }
        nonisolated func events() -> AsyncStream<HermesRPCEvent> { AsyncStream { $0.finish() } }
        func methods() -> [String] { calls.map(\.0) }
        func parameters(_ method: String) -> JSONObject? { calls.first { $0.0 == method }?.1 }
    }

    func testNewTaskCreatesWithinProfileWithoutHistoryOrModelOverrides() async throws {
        let hermes = Hermes(missing: true)
        let source = WebSocketBotChatSource(rpc: hermes)
        let task = try await source.openAgentTask(profile: "forja", taskID: "unique", storedID: nil)
        XCTAssertEqual(task.storedID, "task-stored")
        XCTAssertEqual(task.liveID, "task-live")
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.resume", "session.create"])
        let params = await hermes.parameters("session.create")
        XCTAssertEqual(params?["profile"] as? String, "forja")
        XCTAssertEqual(params?["title"] as? String, "Alice task unique")
        XCTAssertNil(params?["model"])
        XCTAssertNil(params?["provider"])
        XCTAssertNil(params?["messages"])
    }

    func testReconnectAndSubmitUseTheTasksSession() async throws {
        let hermes = Hermes()
        let source = WebSocketBotChatSource(rpc: hermes)
        let task = try await source.openAgentTask(profile: "forja", taskID: "unique", storedID: "task-stored")
        _ = try await source.submit(liveSessionID: task.liveID, text: "Design an agent")
        let resume = await hermes.parameters("session.resume")
        XCTAssertEqual(resume?["profile"] as? String, "forja")
        XCTAssertEqual(resume?["session_id"] as? String, "task-stored")
        let submit = await hermes.parameters("prompt.submit")
        XCTAssertEqual(submit?["session_id"] as? String, "task-live")
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.resume", "prompt.submit"])
    }

    func testLostCreateResponseIsRecoveredByTheSameUniqueTitle() async throws {
        let hermes = Hermes()
        _ = try await WebSocketBotChatSource(rpc: hermes).openAgentTask(profile: "forja", taskID: "unique", storedID: nil)
        let params = await hermes.parameters("session.resume")
        XCTAssertEqual(params?["session_id"] as? String, "Alice task unique")
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.resume"])
    }

    func testMissingSavedTaskDoesNotCreateOrUseCanonicalChat() async {
        let hermes = Hermes(missing: true)
        do {
            _ = try await WebSocketBotChatSource(rpc: hermes).openAgentTask(profile: "forja", taskID: "unique", storedID: "deleted")
            XCTFail("A missing task must fail visibly")
        } catch {}
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.resume"])
    }

    func testOfflineDoesNotCreateAnotherTask() async {
        let hermes = Hermes(offline: true)
        do {
            _ = try await WebSocketBotChatSource(rpc: hermes).openAgentTask(profile: "forja", taskID: "unique", storedID: nil)
            XCTFail("Offline must preserve the task")
        } catch {}
        let methods = await hermes.methods()
        XCTAssertEqual(methods, ["session.resume"])
    }
}

@MainActor
final class AgentTaskConversationTests: XCTestCase {
    func testTaskPreservesCanonicalHistoryDraftAndSessionAcrossRelaunch() throws {
        let suite = "alice.task-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let bot = BotRow(name: "forja", displayName: "Forge", detail: "", model: nil, provider: nil, skills: 0, isDefault: false, gatewayRunning: false, active: true)
        let canonical = store.openBotConversation(for: bot, refresh: false)
        let index = try XCTUnwrap(store.conversations.firstIndex { $0.id == canonical })
        store.conversations[index].hermesSessionID = "canonical-stored"
        store.conversations[index].messages = [Message(id: "old", role: .user, content: "Keep this", createdAt: Date())]
        store.draft = "Unsent in main chat"
        let task = store.openAgentTaskConversation(for: bot)
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertTrue(store.recentConversations.contains { $0.id == task })
        let taskIndex = try XCTUnwrap(store.conversations.firstIndex { $0.id == task })
        store.conversations[taskIndex].hermesSessionID = "task-stored"
        store.persistConversationsImmediately()
        let reopened = AppStore(defaults: defaults)
        let restored = try XCTUnwrap(reopened.conversations.first { $0.id == task })
        XCTAssertTrue(restored.isAgentTask)
        XCTAssertFalse(restored.isCanonicalBotChat)
        XCTAssertEqual(ChatTurnRoute.resolve(in: restored, invokedBot: nil, dashboardReady: false, updatingHermes: false), .agent(profile: "forja", mention: false))
        XCTAssertEqual(restored.hermesSessionID, "task-stored")
        XCTAssertEqual(reopened.openBotConversation(for: bot, refresh: false), canonical)
        XCTAssertEqual(reopened.draft, "Unsent in main chat")
        XCTAssertEqual(reopened.activeConversation?.messages.first?.content, "Keep this")
        XCTAssertEqual(reopened.activeConversation?.hermesSessionID, "canonical-stored")
        let second = reopened.openAgentTaskConversation(for: bot)
        XCTAssertNotEqual(second, task)
        XCTAssertTrue(reopened.conversations.contains { $0.id == task })
        _ = reopened.openBotConversation(for: bot, replacingExisting: true, refresh: false)
        XCTAssertTrue(reopened.conversations.contains { $0.id == task })
        XCTAssertTrue(reopened.conversations.contains { $0.id == second })
    }

    func testRetryBeforeSessionCreationKeepsTheEditedPromptAndAttachments() throws {
        let suite = "alice.task-retry-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let attachment = Attachment(id: "file", name: "brief.txt", mime: "text/plain", kind: .file, data: Data("Brief".utf8))
        let now = Date()
        store.conversations = [Conversation(
            id: "task", title: "New Agent", createdAt: now, updatedAt: now,
            messages: [
                Message(id: "user", role: .user, content: "Old brief", createdAt: now, attachments: [attachment]),
                Message(id: "failed", role: .assistant, content: "", createdAt: now),
            ], botName: "forja", agentTaskID: "task"
        )]
        store.activeID = "task"
        store.retry("failed", text: "Revised brief")
        // Offline: the retry remains editable instead of requiring a nonexistent session.
        XCTAssertEqual(store.draft, "Revised brief")
        XCTAssertEqual(store.draftAttachments, [attachment])
        XCTAssertNil(store.activeConversation?.hermesSessionID)
    }

    func testOldArchivesRemainCanonicalAndPendingRequestsStaySeparate() throws {
        let old = try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"old","botName":"forja","hermesSessionID":"canonical"}"#.utf8))
        XCTAssertTrue(old.isCanonicalBotChat)
        XCTAssertNil(old.agentTaskID)
        var task = old
        task.agentTaskID = "task"
        task.hermesSessionID = "independent"
        let roundTrip = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(roundTrip, task)
        let targets = PendingRequestSessions.targets(in: [old, task])
        XCTAssertEqual(Set(targets.map(\.address.sessionID)), ["canonical", "independent"])
    }
}
