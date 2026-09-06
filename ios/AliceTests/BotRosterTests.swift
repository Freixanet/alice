import XCTest
@testable import Alice

/// The Bots screen lists NAMED Hermes profiles. The main profile — the one
/// `is_default` marks, the one Home chat talks to — is the app's identity,
/// not a bot, and must never appear in the roster.
final class BotRosterTests: XCTestCase {
    private func row(
        _ name: String,
        isDefault: Bool = false,
        displayName: String? = nil
    ) -> BotRow {
        BotRow(
            name: name,
            displayName: displayName ?? name,
            detail: "",
            model: nil,
            provider: nil,
            skills: 0,
            isDefault: isDefault,
            gatewayRunning: false,
            active: false
        )
    }

    private func profilesBody(_ rows: [[String: Any]]) -> [String: Any] {
        ["profiles": rows]
    }

    func testRosterExcludesTheMainProfile() {
        let roster = AppStore.botRoster(from: [
            row("default", isDefault: true, displayName: "Alice"),
            row("radar-ia"),
            row("537"),
        ])
        XCTAssertEqual(roster.map(\.name), ["radar-ia", "537"])
    }

    func testRosterOfAnInstallationWithoutBotsIsEmpty() {
        XCTAssertTrue(AppStore.botRoster(from: [row("default", isDefault: true)]).isEmpty)
    }

    func testProfileRowsMapIsDefaultFaithfully() throws {
        let bots = try DashboardClient.bots(
            from: profilesBody([
                ["name": "default", "display_name": "Alice", "is_default": true],
                ["name": "radar-ia", "display_name": "Radar IA"],
            ]),
            active: "radar-ia"
        )
        XCTAssertEqual(bots.map(\.name), ["default", "radar-ia"])
        XCTAssertEqual(bots.first { $0.name == "default" }?.isDefault, true)
        XCTAssertEqual(bots.first { $0.name == "radar-ia" }?.isDefault, false)
        XCTAssertEqual(bots.first { $0.name == "radar-ia" }?.active, true)
    }

    func testMissingIsDefaultFallsBackToFalse() throws {
        let bots = try DashboardClient.bots(
            from: profilesBody([["name": "radar-ia"]]),
            active: nil
        )
        XCTAssertEqual(bots.map(\.isDefault), [false])
    }
}
