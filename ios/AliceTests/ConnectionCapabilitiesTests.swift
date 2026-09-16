import XCTest
@testable import Alice

final class ConnectionCapabilitiesTests: XCTestCase {
    func testChatIsAvailableEvenWhenTheDashboardIsNot() {
        let rows = ConnectionCapabilities.rows(dashboardReady: false, modelCount: 0)
        XCTAssertEqual(rows.map(\.available), [true, false, false, false])
    }

    func testAFullConnectionListsAgentsManagementAndModels() {
        let rows = ConnectionCapabilities.rows(dashboardReady: true, modelCount: 12)
        XCTAssertEqual(rows.map(\.available), [true, true, true, true])
    }
}

@MainActor
final class AgentMakerNameTests: XCTestCase {
    func testForjaIsShownAsAgentMakerUnlessThePersonRenamedIt() throws {
        let suite = "alice.maker-name.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        XCTAssertEqual(store.botCurrentName(for: AgentMaker.botName), "Agent Maker")
        store.botCustomNames[AgentMaker.botName] = "Mi forja"
        XCTAssertEqual(store.botCurrentName(for: AgentMaker.botName), "Mi forja")
        XCTAssertEqual(AgentMaker.displayIfNeeded(profile: "forja", shown: "Forja"), "Agent Maker")
        XCTAssertEqual(AgentMaker.displayIfNeeded(profile: "forja", shown: "Taller"), "Taller")
        XCTAssertEqual(AgentMaker.displayIfNeeded(profile: "radar-ia", shown: "Forja"), "Forja")
    }
}
