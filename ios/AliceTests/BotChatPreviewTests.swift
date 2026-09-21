import XCTest
@testable import Alice

/// Agents reads each bot's last reply on every redraw; `BotChatPreviews` keeps
/// it until the chat changes. What it hands back must be what reading the chat
/// afresh would say.
@MainActor
final class BotChatPreviewTests: XCTestCase {
    private let opened = Date(timeIntervalSince1970: 1_000_000)

    private func chat(_ messages: [Message]) -> Conversation {
        var conversation = Conversation.blank(title: "researcher")
        conversation.botName = "researcher"
        conversation.messages = messages
        return conversation
    }

    private func reply(_ id: String, _ text: String, at offset: TimeInterval) -> Message {
        Message(
            id: id, role: .assistant, content: text,
            createdAt: opened.addingTimeInterval(offset), botName: "researcher"
        )
    }

    func testThePreviewQuotesTheLastReplyOnOneLine() {
        let preview = BotChatPreview(
            chat([reply("1", "## Hallazgo\n**Tres** competidores", at: 5)]),
            botName: "researcher", quietRuns: []
        )
        XCTAssertEqual(preview.line, "Hallazgo **Tres** competidores".replacingOccurrences(of: "**", with: ""))
        XCTAssertEqual(preview.repliedAt, opened.addingTimeInterval(5))
    }

    func testANewReplyIsSeenAndAnUnchangedChatIsNotReadAgain() {
        let previews = BotChatPreviews()
        var conversation = chat([reply("1", "Primero", at: 1)])
        XCTAssertEqual(previews.preview(for: conversation, botName: "researcher", quietRuns: []).line, "Primero")

        conversation.messages.append(reply("2", "Segundo", at: 2))
        XCTAssertEqual(previews.preview(for: conversation, botName: "researcher", quietRuns: []).line, "Segundo")

        // A reply still streaming changes its last message's text.
        conversation.messages[1].content += " y más"
        XCTAssertEqual(
            previews.preview(for: conversation, botName: "researcher", quietRuns: []).line,
            "Segundo y más"
        )
    }

    func testUnreadFromThePreviewAgreesWithReadingTheWholeChat() {
        let cases: [([Message], Date?)] = [
            ([reply("1", "Nuevo", at: 1)], opened),
            ([reply("1", "Viejo", at: -1)], opened),
            ([reply("1", "Nuevo", at: 3), reply("2", "Anterior", at: -3)], opened),
            ([reply("1", "Nunca abierto", at: -3)], nil),
        ]
        for (messages, openedAt) in cases {
            let full = AppStore.hasUnreadBotContent(
                messages: messages, quietRuns: [], botName: "researcher", openedAt: openedAt
            )
            let newest = BotChatPreview(chat(messages), botName: "researcher", quietRuns: [])
                .newestReplyAt
            let fromPreview = newest.map { $0 > (openedAt ?? .distantPast) } ?? false
            XCTAssertEqual(fromPreview, full, "\(messages.map(\.content)) opened \(String(describing: openedAt))")
        }
    }
}
