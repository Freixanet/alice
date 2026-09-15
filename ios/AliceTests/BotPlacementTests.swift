import XCTest
@testable import Alice

/// An agent Hermes files in a channel (`ui_meta["alice"]`) lands there once;
/// after that its place is the person's.
final class BotPlacementTests: XCTestCase {
    private func bot(
        _ name: String, channel: String? = nil, section: String? = nil,
        order: Int? = nil, revision: Int = 1, sections: [String]? = nil
    ) -> BotRow {
        BotRow(
            name: name, displayName: name, detail: "", model: nil, provider: nil,
            skills: 0, isDefault: false, gatewayRunning: false, active: false,
            placement: channel.map {
                AlicePlacement(
                    channel: $0, section: section, order: order, revision: revision, sections: sections
                )
            }
        )
    }

    func testALayoutOrdersTheSectionsAndDropsOnlyEmptyOnesItLeavesOut() {
        var channel = BotChannel(
            id: "b", name: "Business (Beta)",
            bots: ["chief-of-staff", "biz-mercado", "biz-tech", "own"]
        )
        for name in ["Intelligence Dept.", "Product Dept.", "Engineering Dept.", "Especialistas", "Mine"] {
            channel.addSection(name)
        }
        channel.setSection("Especialistas", for: "biz-mercado")
        channel.setSection("Especialistas", for: "biz-tech")
        channel.setSection("Mine", for: "own")
        channel.toggleSection("Especialistas")

        let layout = ["Intelligence Dept.", "Product Dept.", "Engineering Dept.", "Revenue Dept."]
        let team = [
            bot("chief-of-staff", channel: "Business (Beta)", order: 0, revision: 2, sections: layout),
            bot("biz-mercado", channel: "Business (Beta)", section: "Intelligence Dept.", order: 1, revision: 2, sections: layout),
            bot("biz-tech", channel: "Business (Beta)", section: "engineering dept.", order: 2, revision: 2, sections: layout),
        ]
        let result = BotChannel.applyingPlacements(
            team, to: [channel], applied: ["chief-of-staff": 1, "biz-mercado": 1, "biz-tech": 1]
        )
        let placed = result.channels[0]
        XCTAssertEqual(
            placed.sections,
            ["Intelligence Dept.", "Product Dept.", "Engineering Dept.", "Revenue Dept.", "Mine"]
        )
        XCTAssertNil(placed.section(for: "chief-of-staff"))
        XCTAssertEqual(placed.section(for: "biz-mercado"), "Intelligence Dept.")
        XCTAssertEqual(placed.section(for: "biz-tech"), "Engineering Dept.")
        XCTAssertEqual(placed.section(for: "own"), "Mine")
        XCTAssertTrue(placed.collapsedSections.isEmpty)
    }

    private var team: [BotRow] {
        [
            bot("biz-mercado", channel: "Business (Beta)", section: "Especialistas", order: 1),
            bot("inbox"),
            bot("biz-director", channel: "Business (Beta)", order: 0),
        ]
    }

    func testTheChannelAndSectionAreMadeAndTheTeamArrivesInOrder() {
        let result = BotChannel.applyingPlacements(team, to: [], applied: [:])
        XCTAssertEqual(result.channels.map(\.name), ["Business (Beta)"])
        let channel = result.channels[0]
        XCTAssertEqual(channel.bots, ["biz-director", "biz-mercado"])
        XCTAssertEqual(channel.sections, ["Especialistas"])
        XCTAssertNil(channel.section(for: "biz-director"))
        XCTAssertEqual(channel.section(for: "biz-mercado"), "Especialistas")
        XCTAssertEqual(result.applied, ["biz-director": 1, "biz-mercado": 1])
    }

    func testAnExistingChannelAndSectionAreFoundWhateverTheirCase() {
        var existing = BotChannel(id: "b", name: "business (beta)", bots: ["537"])
        existing.addSection("especialistas")
        let result = BotChannel.applyingPlacements(team, to: [existing], applied: [:])
        XCTAssertEqual(result.channels.count, 1)
        XCTAssertEqual(result.channels[0].id, "b")
        XCTAssertEqual(result.channels[0].name, "business (beta)")
        XCTAssertEqual(result.channels[0].bots, ["537", "biz-director", "biz-mercado"])
        XCTAssertEqual(result.channels[0].sections, ["especialistas"])
        XCTAssertEqual(result.channels[0].section(for: "biz-mercado"), "especialistas")
    }

    func testAPlacementIsAppliedOnceAndANewRevisionAgain() {
        let first = BotChannel.applyingPlacements(team, to: [], applied: [:])
        var moved = first.channels
        moved[0].remove("biz-mercado")

        let again = BotChannel.applyingPlacements(team, to: moved, applied: first.applied)
        XCTAssertEqual(again.channels, moved)

        let revised = [bot("biz-mercado", channel: "Business (Beta)", section: "Especialistas", revision: 2)]
        let reapplied = BotChannel.applyingPlacements(revised, to: moved, applied: first.applied)
        XCTAssertEqual(reapplied.channels[0].bots, ["biz-director", "biz-mercado"])
        XCTAssertEqual(reapplied.applied["biz-mercado"], 2)
    }

    func testADeletedChannelIsNotMadeAgain() {
        let first = BotChannel.applyingPlacements(team, to: [], applied: [:])
        let again = BotChannel.applyingPlacements(team, to: [], applied: first.applied)
        XCTAssertTrue(again.channels.isEmpty)
    }

    func testTheRosterReadsThePlacement() throws {
        let object: [String: Any] = ["profiles": [
            [
                "name": "biz-mercado",
                "ui_meta": [
                    "hermes-bots": ["title": "Mercado"],
                    "alice": [
                        "channel": "Business (Beta)", "section": "Intelligence Dept.", "order": 1,
                        "sections": ["Intelligence Dept.", " ", "Revenue Dept."],
                    ],
                ],
                "ui_meta_revisions": ["hermes-bots": 1, "alice": 2],
            ],
            ["name": "inbox", "ui_meta": ["alice": ["channel": "  "]]],
            ["name": "evals-sandbox", "ui_meta": [
                "hermes-bots": ["title": "Evals · pruebas", "hidden": true],
                "alice": ["internal": true],
            ]],
        ]]
        let bots = try DashboardClient.bots(from: object, active: nil)
        XCTAssertEqual(bots.map(\.name), ["biz-mercado", "inbox"], "an internal profile is not an agent")
        XCTAssertEqual(
            bots[0].placement,
            AlicePlacement(
                channel: "Business (Beta)", section: "Intelligence Dept.", order: 1, revision: 2,
                sections: ["Intelligence Dept.", "Revenue Dept."]
            )
        )
        XCTAssertEqual(bots[0].displayName, "Mercado")
        XCTAssertNil(bots[1].placement)
    }
}
