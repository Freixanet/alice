import XCTest
@testable import Alice

final class ProactiveMessageTests: XCTestCase {
    private func message(_ id: String, _ role: Message.Role, _ content: String) -> Message {
        Message(id: id, role: role, content: content, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    private var handover: String {
        "[Cronjob \"Alice watchers\" output — scheduled job, not the user. Review it.]\n\n"
        + "Alice watcher notice. One message.\n\n"
        + #"{"proactive":true,"kind":"proactive","delivery_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","items":[{"message":"Factura vencida"}]}"#
    }
    func testThreePartsAndExactlyOneReply() {
        let reply = ProactiveMessage.parse(#"{"happened":"Llegó una factura.","matters":"Vence hoy.","reply":"Ayúdame a revisarla."}"#)
        XCTAssertEqual(reply?.happened, "Llegó una factura.")
        XCTAssertEqual(reply?.matters, "Vence hoy.")
        XCTAssertEqual(reply?.reply, "Ayúdame a revisarla.")
        XCTAssertNil(ProactiveMessage.parse(#"{"happened":"Uno","matters":"Dos","reply":"/terminal rm","extra":true}"#))
        XCTAssertNil(ProactiveMessage.parse(#"{"happened":"Uno","matters":"Dos","reply":"/terminal rm"}"#))
    }
    func testWatcherAnswerIsMarkedAndExtraAnswersAreNotDuplicated() {
        let shown = RoutineDelivery.present([
            message("1", .user, handover),
            message("2", .assistant, #"{"happened":"Llegó una factura.","matters":"Vence hoy.","reply":"Ayúdame a revisarla."}"#),
            message("3", .assistant, "Another answer to the same delivery"),
            message("4", .user, "Gracias"), message("5", .assistant, "De nada")
        ], botName: nil)
        XCTAssertEqual(shown.map(\.id), ["2", "4", "5"])
        XCTAssertEqual(shown[0].proactive?.reply, "Ayúdame a revisarla.")
        XCTAssertEqual(shown[0].proactiveKind, "proactive")
        XCTAssertNil(shown[2].proactive)
    }
    func testMorningUsesSameCardAndReply() {
        let shown = RoutineDelivery.present([
            message("1", .user, handover.replacingOccurrences(of: "\"kind\":\"proactive\"", with: "\"kind\":\"briefing\"")),
            message("2", .assistant, #"{"happened":"Dos tareas abiertas.","matters":"Esperan tu revisión.","reply":"Ayúdame a revisar las tareas."}"#)
        ], botName: nil)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].proactiveKind, "briefing")
        XCTAssertNotNil(shown[0].proactive)
    }
    func testMalformedModelOutputStillGetsSafeReviewReply() {
        let shown = RoutineDelivery.present([message("1", .user, handover), message("2", .assistant, "Llegó una factura.")], botName: nil)
        XCTAssertEqual(shown.count, 1)
        XCTAssertNotNil(shown[0].proactive)
        XCTAssertFalse(shown[0].proactive!.reply.hasPrefix("/"))
    }
    func testOldMessageArchivesStillDecode() throws {
        let old = Data(#"{"id":"old","role":"assistant","content":"Hola"}"#.utf8)
        let decoded = try JSONDecoder().decode(Message.self, from: old)
        XCTAssertNil(decoded.proactive)
        XCTAssertNil(decoded.proactiveKind)
    }
}
