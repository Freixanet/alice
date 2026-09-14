import XCTest
@testable import Alice

/// A channel is a folder of bots and teams, never a chat of its own.
final class BotChannelTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_789_500_000)

    func testABotCanBeInSeveralChannelsAndLeavesTheGeneralList() {
        let work = BotChannel(name: "Work", bots: ["radar-ia", "chollometro", "radar-ia"])
        let news = BotChannel(name: "News", bots: ["radar-ia", "537"])
        XCTAssertEqual(work.bots, ["radar-ia", "chollometro"])
        XCTAssertEqual(BotChannel.members(of: [work, news]), ["radar-ia", "chollometro", "537"])
    }

    func testSectionsInsideAChannelFollowItsBots() {
        var channel = BotChannel(name: "Work", bots: ["radar-ia", "chollometro"])
        XCTAssertTrue(channel.addSection("Daily"))
        XCTAssertFalse(channel.addSection("  Daily "))
        channel.setSection("Daily", for: "radar-ia")
        channel.setSection("Missing", for: "chollometro")
        XCTAssertEqual(channel.section(for: "radar-ia"), "Daily")
        XCTAssertNil(channel.section(for: "chollometro"))

        channel.toggleSection("Daily")
        XCTAssertEqual(channel.collapsedSections, ["Daily"])

        channel.setBots(["chollometro"])
        XCTAssertNil(channel.section(for: "radar-ia"))
        XCTAssertEqual(channel.bots, ["chollometro"])

        channel.add("radar-ia")
        channel.setSection("Daily", for: "radar-ia")
        channel.deleteSection("Daily")
        XCTAssertEqual(channel.bots, ["chollometro", "radar-ia"])
        XCTAssertNil(channel.section(for: "radar-ia"))
        XCTAssertTrue(channel.collapsedSections.isEmpty)
    }

    func testRenamingABotCarriesItsPlaceInTheChannel() {
        var channel = BotChannel(name: "Work", bots: ["radar", "chollometro"])
        channel.addSection("Daily")
        channel.setSection("Daily", for: "radar")
        channel.rename(bot: "radar", to: "radar-ia")
        XCTAssertEqual(channel.bots, ["radar-ia", "chollometro"])
        XCTAssertEqual(channel.section(for: "radar-ia"), "Daily")
    }

    func testAnEmptyLegacyChannelBecomesAnEmptyFolderAndNoChat() {
        let legacy = Conversation(
            id: "c1", title: "#new channel", createdAt: when, updatedAt: when,
            isChannel: true, channelBots: []
        )
        let home = Conversation(id: "h", title: "Hola", createdAt: when, updatedAt: when)

        let first = BotChannel.migratingLegacyChannels([legacy, home], into: [])
        XCTAssertEqual(first.conversations.map(\.id), ["h"])
        XCTAssertEqual(first.channels.map(\.name), ["new channel"])
        XCTAssertEqual(first.channels.first?.bots, [])

        let again = BotChannel.migratingLegacyChannels(first.conversations, into: first.channels)
        XCTAssertEqual(again.conversations, first.conversations)
        XCTAssertEqual(again.channels, first.channels)
    }

    func testALegacyChannelWithAHistoryKeepsItAsATeam() {
        let legacy = Conversation(
            id: "c2", title: "#ops", createdAt: when, updatedAt: when,
            messages: [Message(id: "m", role: .user, content: "@radar-ia hola", createdAt: when)],
            isChannel: true, channelBots: ["radar-ia", "chollometro"]
        )
        let migrated = BotChannel.migratingLegacyChannels([legacy], into: [])
        let channel = try? XCTUnwrap(migrated.channels.first)
        XCTAssertEqual(channel?.name, "ops")
        XCTAssertEqual(channel?.bots, ["radar-ia", "chollometro"])
        XCTAssertEqual(migrated.conversations.first?.teamChannelID, channel?.id)
        XCTAssertEqual(migrated.conversations.first?.messages.count, 1)
    }

    func testSavedChannelsFromAnOlderBuildStillDecode() throws {
        let data = Data(#"[{"id":"x","name":"Work","bots":["537"]}]"#.utf8)
        let decoded = try JSONDecoder().decode([BotChannel].self, from: data)
        XCTAssertEqual(decoded.first?.bots, ["537"])
        XCTAssertEqual(decoded.first?.collapsed, false)
        XCTAssertEqual(decoded.first?.sections, [])

        let roundTrip = try JSONDecoder().decode([BotChannel].self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }
}
