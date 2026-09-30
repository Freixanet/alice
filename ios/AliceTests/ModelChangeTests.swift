import XCTest
@testable import Alice

/// A reply from another model than the one before it says so in the chat (`ModelChange`).
final class ModelChangeTests: XCTestCase {
    private func reply(_ id: String, _ model: String?) -> Message {
        var message = Message(id: id, role: .assistant, content: "Hola", createdAt: Date())
        message.usage = model.map { MessageUsage(model: $0) }
        return message
    }

    func testOnlyTheReplyWhereTheModelChangesIsMarked() {
        let messages = [reply("a", "grok-4.7"), Message(id: "u", role: .user, content: "sigue", createdAt: Date()),
                        reply("b", "grok-4.7"), reply("c", nil), reply("d", "gpt-5.6-terra"), reply("e", "gpt-5.6-terra")]
        let changes = ModelChange.changes(in: messages)
        XCTAssertEqual(changes.keys.sorted(), ["d"])
        XCTAssertEqual(changes["d"], ModelChange(from: "grok-4.7", to: "gpt-5.6-terra"))
        XCTAssertEqual(changes["d"]?.said(in: .spanish), "Ahora responde gpt-5.6-terra (antes grok-4.7)")
    }
}
