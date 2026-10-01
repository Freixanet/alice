import XCTest
@testable import Alice

final class ErrandTranscriptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let request = "Compra la creatina Creapure de Prozis"

    private func errand(_ id: String = "e1", session: String = "chat-1", offset: TimeInterval = 1) -> Errand {
        Errand.parse([
            "id": id, "title": request, "request": request, "origin_session": session,
            "status": "working", "started_at": start.addingTimeInterval(offset).timeIntervalSince1970,
            "updated_at": start.addingTimeInterval(offset).timeIntervalSince1970,
        ])!
    }

    private func message(_ id: String, _ role: Message.Role, _ text: String,
                         offset: TimeInterval = 0, ref: String? = nil, pending: Bool = false) -> Message {
        let tools = ref.map {
            [Message.ToolCall(id: "call-\(id)", name: "errand_start", status: .done,
                              detail: "{\"result\":{\"errand_id\":\"\($0)\"}}")]
        } ?? []
        return Message(id: id, role: role, content: text, createdAt: start.addingTimeInterval(offset),
                       pending: pending, tools: tools)
    }

    func testSeveralRepliesAndToolCallsShareOneCard() {
        let messages = [message("u", .user, request),
                        message("a1", .assistant, "En marcha", ref: "e1"),
                        message("a2", .assistant, "Sigue en marcha", ref: "e1")]
        let placements = ErrandTranscript.placements(messages: messages, errands: [errand()], session: "chat-1")
        // One card, anchored to the first reply about this task.
        XCTAssertEqual(placements.keys.sorted(), ["a1"])
        XCTAssertEqual(placements["a1"]?.map(\.errandID), ["e1"])
    }

    func testTheCardStaysWithItsStartingReplyAcrossLaterTurnsAndStateChanges() {
        var moving = errand()
        moving.updatedAt = start.addingTimeInterval(100)
        let messages = [message("u", .user, request), message("a1", .assistant, "En marcha", ref: "e1"),
                        message("u2", .user, "¿Y el envío?", offset: 50), message("a2", .assistant, "Gratis", offset: 51),
                        message("u3", .user, "Otra cosa", offset: 200)]
        // Later turns never move the browser or the purchase block.
        XCTAssertEqual(ErrandTranscript.placements(messages: messages, errands: [moving], session: "chat-1").keys.sorted(), ["a1"])
        moving.status = .stuck
        let placements = ErrandTranscript.placements(messages: messages, errands: [moving], session: "chat-1")
        XCTAssertEqual(placements.keys.sorted(), ["a1"], "state changes retain the original transcript anchor")
    }

    func testClockAllowanceNeverAttachesToAnUnrelatedEarlierTurn() {
        let messages = [message("old-u", .user, "Cambia el modelo", offset: -30),
                        message("old-a", .assistant, "Elige un modelo", offset: -29),
                        message("u", .user, request),
                        message("a1", .assistant, "En marcha"),
                        message("a2", .assistant, "Sigue en marcha")]
        let placements = ErrandTranscript.placements(messages: messages, errands: [errand()], session: "chat-1")
        XCTAssertEqual(placements.keys.sorted(), ["a1"])
    }

    func testAutomaticStartIsFoundWithWhitespaceAndCaseDifferences() {
        let messages = [message("u", .user, "  COMPRA la creatina\nCreapure de Prozis "),
                        message("a", .assistant, "En marcha")]
        XCTAssertEqual(ErrandTranscript.placements(messages: messages, errands: [errand()],
                                                   session: "chat-1")["a"]?.count, 1)
    }

    func testTitleOnlyCallCannotPickANewerPurchaseFromAnotherChat() {
        var reply = message("a", .assistant, "En marcha")
        reply.tools = [Message.ToolCall(id: "call", name: "errand_start", status: .done,
                                       detail: "{\"args\":{\"title\":\"\(request)\"}}")]
        let placements = ErrandTranscript.placements(
            messages: [message("u", .user, request), reply],
            errands: [errand(), errand("foreign", session: "other-chat", offset: 2)], session: "chat-1")
        XCTAssertEqual(placements["a"]?.map(\.errandID), ["e1"])
    }

    func testLaterPurchaseWithTheSameTitleKeepsItsOwnTurn() {
        let messages = [message("u1", .user, request), message("a1", .assistant, "En marcha"),
                        message("u2", .user, request, offset: 86_400),
                        message("a2", .assistant, "En marcha", offset: 86_400)]
        var first = errand()
        first.status = .done
        let placements = ErrandTranscript.placements(
            messages: messages, errands: [first, errand("e2", offset: 86_401)], session: "chat-1")
        XCTAssertEqual(placements["a1"]?.map(\.errandID), ["e1"])
        XCTAssertEqual(placements["a2"]?.map(\.errandID), ["e2"])
    }

    func testPendingEmptyReplyDoesNotDrawTheCardBeforeItsWords() {
        let messages = [message("u", .user, request),
                        message("a", .assistant, "", ref: "e1", pending: true)]
        XCTAssertTrue(ErrandTranscript.placements(messages: messages, errands: [errand()], session: "chat-1").isEmpty)
    }

    func testClockSkewRequiresTheSameRequestAndSession() {
        let messages = [message("u", .user, request, offset: 60),
                        message("a", .assistant, "En marcha", offset: 61)]
        XCTAssertEqual(ErrandTranscript.placements(messages: messages, errands: [errand()],
                                                   session: "chat-1")["a"]?.count, 1)
        XCTAssertTrue(ErrandTranscript.placements(messages: messages, errands: [errand()], session: "other").isEmpty)
    }

    func testDuplicateBackendRowsStillProduceOneCard() {
        let messages = [message("u", .user, request), message("a", .assistant, "En marcha")]
        XCTAssertEqual(ErrandTranscript.placements(messages: messages, errands: [errand(), errand()],
                                                   session: "chat-1")["a"]?.count, 1)
    }
}
