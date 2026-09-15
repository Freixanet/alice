import XCTest
@testable import Alice

/// What an agent's Live Activity says.
final class AgentActivityTests: XCTestCase {
    func testTheStatusSaysWhoTheAgentIsWaitingFor() {
        XCTAssertEqual(AgentActivityText.waiting(for: []), "Working")
        XCTAssertEqual(AgentActivityText.waiting(for: ["Mercado"]), "Waiting for Mercado")
        XCTAssertEqual(AgentActivityText.waiting(for: ["Mercado", "Producto"]), "Waiting for Mercado and Producto")
        XCTAssertEqual(AgentActivityText.waiting(for: ["Mercado", "Producto", "Growth"]), "Waiting for Mercado and 2 more")
    }

    func testAnEndedActivitySaysHowItEnded() {
        XCTAssertEqual(AgentActivityText.ended(.finished), "Done")
        XCTAssertEqual(AgentActivityText.ended(.failed), "Failed")
        XCTAssertEqual(AgentActivityText.ended(.stopped), "Stopped")
    }

    func testTheStateTravelsIntact() throws {
        let start = Date(timeIntervalSince1970: 1_789_500_000)
        let state = AgentActivityAttributes.ContentState(
            phase: .waiting, detail: "Waiting for Mercado", startedAt: start,
            endedAt: nil, updatedAt: start.addingTimeInterval(60)
        )
        let decoded = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
        XCTAssertFalse(decoded.isDone)
    }
}
