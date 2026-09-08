import XCTest
@testable import Alice

/// What Hermes 0.21 actually serves for skills, and what Alice may claim on
/// the strength of it.
final class SkillsApiTests: XCTestCase {

    // MARK: - Listing

    /// The dashboard's `GET /api/skills` answers with a bare array whose rows
    /// carry `enabled`. That is the listing worth reading: the gateway's
    /// `/v1/skills` reports a name and a description and nothing about state.
    func testDashboardListingCarriesState() throws {
        let body = Data("""
        [
          {"name": "research", "description": "Look things up", "enabled": true},
          {"name": "drafting", "description": "Write things", "enabled": false}
        ]
        """.utf8)

        let rows = try DashboardClient.rows(from: body, shape: .array)
        let catalog = HermesClient.parseCatalog(rows, kind: .skill)

        XCTAssertEqual(catalog.map(\.name), ["research", "drafting"])
        XCTAssertEqual(catalog.map(\.enabled), [true, false])
    }

    /// The gateway's listing says nothing about whether a skill is on. That
    /// has to stay unknown rather than become "off": a switch drawn from an
    /// invented `false` claims the agent said something it did not.
    func testGatewayListingLeavesStateUnknown() throws {
        let body = Data("""
        {"object": "list", "data": [{"name": "research", "description": "Look things up"}]}
        """.utf8)

        let catalog = HermesClient.parseCatalog(
            try HermesClient.catalogRows(from: body), kind: .skill
        )

        XCTAssertEqual(catalog.count, 1)
        XCTAssertNil(catalog[0].enabled)
    }

    /// A body this code cannot read is not a claim that there are no skills.
    func testUnreadableListingDoesNotBecomeAnEmptyCatalogue() {
        for body in ["<html>gateway restarting</html>", "\"nope\"", "{\"error\": \"boom\"}"] {
            XCTAssertThrowsError(
                try HermesClient.catalogRows(from: Data(body.utf8)),
                "\(body) must not pass as an empty listing"
            )
        }
    }

    func testEnvelopeKeysAreStillAccepted() throws {
        let envelopes = [
            "{\"skills\": [{\"name\": \"a\"}]}",
            "{\"data\": [{\"name\": \"a\"}]}",
            "{\"items\": [{\"name\": \"a\"}]}",
            "[{\"name\": \"a\"}]",
        ]
        for body in envelopes {
            let rows = try HermesClient.catalogRows(from: Data(body.utf8))
            XCTAssertEqual(rows.count, 1, body)
        }
    }

    /// An envelope that genuinely holds no rows is a real answer.
    func testEmptyListingIsAnAnswer() throws {
        XCTAssertTrue(try HermesClient.catalogRows(from: Data("[]".utf8)).isEmpty)
        XCTAssertTrue(
            try HermesClient.catalogRows(from: Data("{\"skills\": []}".utf8)).isEmpty
        )
    }

    // MARK: - Writing

    /// Hermes keeps creating and editing apart: `POST /api/skills` builds the
    /// skill directory through the agent's own write path, `PUT
    /// /api/skills/content` replaces the SKILL.md of one that already exists.
    /// Sending an edit to the create route makes a second skill; sending a
    /// creation to the edit route is a 404. There is no route on either half
    /// of Hermes 0.21 that deletes a skill.
    func testSaveUsesTheRouteThatMatchesTheWrite() async throws {
        StubProtocol.install { _, _ in .init(status: 200) }
        let client = await makeStubbedDashboard()

        try await client.saveSkill(name: "research", content: "---\nname: research\n---\n", isNew: true)
        try await client.saveSkill(name: "research", content: "---\nname: research\n---\n", isNew: false)

        XCTAssertEqual(StubProtocol.count("POST", "/api/skills"), 1)
        XCTAssertEqual(StubProtocol.count("PUT", "/api/skills/content"), 1)
        XCTAssertEqual(StubProtocol.count("POST", "/api/skills/save"), 0)
    }

    /// The toggle is a PUT. It was a POST, against a gateway that serves no
    /// skills toggle at all, so it could only ever have 404ed.
    func testToggleIsAPutOnTheDashboard() async throws {
        StubProtocol.install { _, _ in .init(status: 200) }
        let client = await makeStubbedDashboard()

        try await client.setSkillEnabled("research", enabled: false, profile: nil)

        XCTAssertEqual(StubProtocol.count("PUT", "/api/skills/toggle"), 1)
        XCTAssertEqual(StubProtocol.count("POST", "/api/skills/toggle"), 0)
    }
}
