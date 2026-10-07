import XCTest
@testable import Alice

/// What Alice learned is said under the reply it came after, plainly (`LessonNotice`).
final class LessonNoticeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func reply(_ id: String, _ minutes: Double) -> Message {
        Message(id: id, role: .assistant, content: "Hola", createdAt: start.addingTimeInterval(minutes * 60))
    }

    private func action(_ kind: String, _ minutes: Double, profile: String = "default") -> AgentAction {
        AgentAction(id: UUID().uuidString, at: start.addingTimeInterval(minutes * 60), profile: profile, session: nil,
                    kind: kind, target: "x", ok: true, place: .chat, originTitle: "", routineKey: nil)
    }

    private func user(_ id: String, _ minutes: Double) -> Message {
        Message(id: id, role: .user, content: "sigue", createdAt: start.addingTimeInterval(minutes * 60))
    }

    func testALessonGoesUnderTheReplyOfItsTurn() {
        // Asked at 10; learned at 12 while answering; the answer ends at 12.05.
        let messages = [reply("a", 0), user("u", 10), reply("b", 12.05), user("v", 20), reply("c", 21)]
        XCTAssertEqual(Array(LessonNotice.replies(in: messages, actions: [action("skill.learned", 12)]).keys), ["b"])
        // A review after the chat paused goes under the reply before it.
        XCTAssertEqual(Array(LessonNotice.replies(in: messages, actions: [action("skill.learned", 23)]).keys), ["c"])
    }

    func testOnlyAKeptLessonInTimeIsSaid() {
        let messages = [reply("a", 0), user("u", 10), reply("b", 11)]
        let marked = LessonNotice.replies(in: messages, actions: [
            action("skill.learned", 2), action("skill.learned", 3, profile: "inbox"),
            action("skill.held", 11), action("skill.proposed", 11), action("skill.learned", 90),
        ])
        XCTAssertEqual(Array(marked.keys), ["a"])
        XCTAssertEqual(marked["a"]?.count, 2)
        XCTAssertEqual(LessonNotice.said(in: .spanish), "He aprendido algo para la próxima vez")
    }
}
