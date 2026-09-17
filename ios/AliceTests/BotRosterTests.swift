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

    func testRosterReadsAgentMakerRole() throws {
        let bots = try DashboardClient.bots(
            from: profilesBody([
                ["name": "taller", "display_name": "Taller",
                 "ui_meta": ["alice": ["role": "agent-maker"], "hermes-bots": ["title": "Taller"]]],
                ["name": "evals-sandbox", "ui_meta": ["alice": ["internal": true]]],
            ]),
            active: nil
        )
        XCTAssertEqual(bots.map(\.name), ["taller"])
        XCTAssertEqual(bots.first?.aliceRole, "agent-maker")
        XCTAssertTrue(AgentMaker.matches(profile: bots[0].name, role: bots[0].aliceRole))
    }
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
    func testBotModeMetadataWinsPresentationAndCarriesRevision() throws {
        let bots = try DashboardClient.bots(
            from: profilesBody([[
                "name": "radar-ia",
                "display_name": "Old profile label",
                "description": "Profile description",
                "model": "grok-4.6",
                "provider": "xai-oauth",
                "skill_count": NSNumber(value: 60),
                "ui_meta": [
                    "hermes-bots": [
                        "title": "Radar IA",
                        "description": "Bot Mode description",
                        "hidden": true,
                        "pinned": false,
                        "shape": "blobatar",
                        "groups": ["news"],
                        "managedTemplateId": "radar-ia",
                        "managedTemplateVersion": NSNumber(value: 3),
                        "created": NSNumber(value: 1_788_304_483_659 as Int64),
                    ]
                ],
                "ui_meta_revisions": ["hermes-bots": NSNumber(value: 7)],
            ]]),
            active: nil
        )
        let bot = try XCTUnwrap(bots.first)
        XCTAssertEqual(bot.displayName, "Radar IA")
        XCTAssertEqual(bot.detail, "Bot Mode description")
        XCTAssertEqual(bot.model, "grok-4.6")
        XCTAssertEqual(bot.provider, "xai-oauth")
        XCTAssertEqual(bot.skills, 60)
        XCTAssertTrue(bot.hidden)
        XCTAssertFalse(bot.pinned)
        XCTAssertEqual(bot.metadata.shape, "blobatar")
        XCTAssertEqual(bot.metadata.groups, ["news"])
        XCTAssertEqual(bot.metadata.managedTemplateID, "radar-ia")
        XCTAssertEqual(bot.metadata.managedTemplateVersion, 3)
        XCTAssertEqual(bot.metadata.revision, 7)
        XCTAssertTrue(bot.metadata.present)
    }

    func testLegacyNamedProfileRemainsABotWithoutMetadata() throws {
        let rows = try DashboardClient.bots(
            from: profilesBody([[
                "name": "researcher",
                "description": "Research work",
                "is_default": false,
            ]]),
            active: nil
        )
        let roster = AppStore.botRoster(from: rows)
        XCTAssertEqual(roster.map(\.name), ["researcher"])
        XCTAssertFalse(try XCTUnwrap(roster.first).metadata.present)
    }

    func testDefaultNeverBecomesBotEvenWithHermesBotsMetadata() throws {
        let rows = try DashboardClient.bots(
            from: profilesBody([
                [
                    "name": "default", "display_name": "Alice", "is_default": true,
                    "ui_meta": ["hermes-bots": ["pinned": true, "title": "Alice"]],
                ],
                ["name": "537", "is_default": false],
            ]),
            active: nil
        )
        XCTAssertEqual(AppStore.botRoster(from: rows).map(\.name), ["537"])
    }

    func testRestFallbackCarriesLastKnownBotModeMetadata() {
        var cached = row("radar-ia")
        cached.displayName = "Radar IA"
        cached.metadata = BotMetadata(
            title: "Radar IA", hidden: true, pinned: true, revision: 4, present: true
        )
        let carried = AppStore.carryCachedMetadata([row("radar-ia")], from: [cached])
        XCTAssertEqual(carried.first?.displayName, "Radar IA")
        XCTAssertTrue(carried.first?.hidden == true)
        XCTAssertTrue(carried.first?.pinned == true)
        XCTAssertEqual(carried.first?.metadata.revision, 4)
    }

    func testBotSlugMatchesHermesBotModeGrammar() {
        XCTAssertEqual(AppStore.botSlug("My Research Bot!"), "my-research-bot")
        XCTAssertEqual(AppStore.botSlug("  RADAR_IA  "), "radar_ia")
        XCTAssertEqual(AppStore.botSlug("!!!"), "")
        XCTAssertLessThanOrEqual(AppStore.botSlug(String(repeating: "A", count: 100)).count, 64)
    }

    func testADeletedOrLiveSlugIsNotReusedForASimilarName() {
        XCTAssertEqual(
            AppStore.uniqueBotSlug("Agente Prueba", taken: []),
            "agente-prueba"
        )
        XCTAssertEqual(
            AppStore.uniqueBotSlug("Agente Prueba", taken: ["agente-prueba"]),
            "agente-prueba-2"
        )
        XCTAssertEqual(
            AppStore.uniqueBotSlug("Agente Prueba", taken: ["agente-prueba", "agente-prueba-2"]),
            "agente-prueba-3"
        )
        XCTAssertEqual(
            AppStore.uniqueBotSlug("Agente Prueba", taken: ["Agente-Prueba"]),
            "agente-prueba-2"
        )
    }

    func testSavedBotOrderWinsWhileUnknownBotsStayStableAtTheEnd() {
        let rows = [row("a"), row("b"), row("c"), row("new-1"), row("new-2")]
        let ordered = AppStore.orderedBots(rows, using: ["c", "a", "b"])
        XCTAssertEqual(ordered.map(\.name), ["c", "a", "b", "new-1", "new-2"])
    }

    func testMovingBotDownLandsAfterTargetAndMovingUpBeforeTarget() {
        XCTAssertEqual(
            AppStore.movingBot("a", relativeTo: "c", within: ["a", "b", "c", "d"]),
            ["b", "c", "a", "d"]
        )
        XCTAssertEqual(
            AppStore.movingBot("d", relativeTo: "b", within: ["a", "b", "c", "d"]),
            ["a", "d", "b", "c"]
        )
    }

    func testMergingSectionOrderDoesNotReshuffleOtherSections() {
        let merged = AppStore.mergingBotOrder(
            ["work-a", "personal-a", "work-b", "personal-b"],
            allNames: ["work-a", "personal-a", "work-b", "personal-b"],
            orderedPeers: ["work-b", "work-a"]
        )
        XCTAssertEqual(merged, ["work-b", "personal-a", "work-a", "personal-b"])
    }

    func testMergingOrderAddsNewBotsOnce() {
        let merged = AppStore.mergingBotOrder(
            ["a", "a"], allNames: ["a", "b", "c"], orderedPeers: ["c", "b"]
        )
        XCTAssertEqual(merged, ["a", "c", "b"])
    }

}
