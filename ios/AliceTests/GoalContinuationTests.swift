import XCTest
@testable import Alice

final class GoalContinuationTests: XCTestCase {
    func testHermesSendingTheAgentBackToATaskIsNotShownAsThePersonWritingIt() {
        let rows: [[String: Any]] = [
            ["row_id": "1", "role": "user", "text": "Cómprame el pienso"],
            ["row_id": "2", "role": "assistant", "text": "La tienda marca la dirección como incompleta."],
            ["row_id": "3", "role": "user", "text": "[Continuing toward your standing goal]\nGoal: Comprar pienso"],
            ["row_id": "4", "role": "assistant", "text": "He completado la dirección; el pedido está listo para pagar."],
        ]
        let turns = WebSocketBotChatSource.turns(from: rows)
        XCTAssertEqual(turns.map(\.id), ["1", "2", "4"])
    }
}
