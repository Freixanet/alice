import XCTest
@testable import Alice

/// Search could only find conversations. In an app whose drawer holds thirteen
/// destinations, several named after Hermes internals, that left someone who
/// does not already know that "MCP" means integrations with no way to get
/// there except opening screens until one was right.
final class DestinationSearchTests: XCTestCase {

    private func target(_ query: String) -> [AliceDestination.Target] {
        AliceDestination.matching(query).map(\.target)
    }

    /// The words a person actually types, none of which is the name of the
    /// screen that holds the thing.
    func testHumanWordsReachTheRightScreen() {
        let expectations: [(String, AliceDestination.Target)] = [
            ("notifications", .activity),
            ("telegram", .channels),
            ("reconnect", .channels),
            ("cron", .routines),
            ("automation", .routines),
            ("daily", .routines),
            ("api key", .models),
            ("how much", .usage),
            ("cost", .usage),
            ("what it knows about me", .memory),
            ("forget", .memory),
            ("integration", .mcp),
            ("logs", .system),
            ("backup", .system),
            ("dark mode", .settings),
            ("offline", .connect),
            ("pull request", .git),
        ]
        for (query, expected) in expectations {
            XCTAssertTrue(
                target(query).contains(expected),
                "“\(query)” should reach \(expected.rawValue), got \(target(query))"
            )
        }
    }

    /// An expert searches Hermes' vocabulary. The same list has to serve them,
    /// which is the whole reason the technical names were kept.
    func testHermesVocabularyStillWorks() {
        let expectations: [(String, AliceDestination.Target)] = [
            ("mcp", .mcp),
            ("profiles", .bots),
            ("webhook", .webhooks),
            ("gateway", .system),
            ("cron", .routines),
            ("artifacts", .library),
            ("worktree", .git),
            ("config.yaml", .configuration),
        ]
        for (query, expected) in expectations {
            XCTAssertTrue(
                target(query).contains(expected),
                "“\(query)” should reach \(expected.rawValue), got \(target(query))"
            )
        }
    }

    /// Renaming a screen must not erase Hermes' word for it: an expert has to
    /// be able to confirm they are in the right place, and a newcomer has to be
    /// able to connect what they read here with anything written about Hermes.
    func testRenamedDestinationsKeepTheHermesTerm() {
        let renamed: [AliceDestination.Target: String] = [
            .mcp: "MCP",
            .routines: "Cron",
            .bots: "Hermes profiles",
            .library: "Artifacts",
            .tools: "Toolsets",
        ]
        for (target, term) in renamed {
            let place = AliceDestination.all.first { $0.target == target }
            XCTAssertEqual(place?.technical, term, "\(target.rawValue) lost its Hermes term")
        }
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertTrue(AliceDestination.matching("").isEmpty)
        XCTAssertTrue(AliceDestination.matching("   ").isEmpty)
    }

    /// Two destinations sharing an id would collide in any list built from
    /// them, and a duplicate row is the visible symptom.
    func testDestinationIdsAreUnique() {
        let ids = AliceDestination.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Every destination the drawer can open must exist in the searchable list,
    /// or it is reachable only by knowing where it already is.
    func testEverySearchableTargetIsCovered() {
        let covered = Set(AliceDestination.all.map(\.target))
        for target in [
            AliceDestination.Target.bots, .activity, .routines, .projects, .files,
            .library, .channels, .mcp, .skills, .tools, .webhooks, .git, .system,
            .settings, .connect, .memory, .models, .usage, .sessions, .insights,
            .configuration, .pairing, .plugins,
        ] {
            XCTAssertTrue(covered.contains(target), "\(target.rawValue) is not searchable")
        }
    }
}

/// Reachability and health are different questions, and one Boolean called
/// `isConnected` — set once when a request first succeeded and never revisited
/// — was answering both by answering neither.
@MainActor
final class WellbeingTests: XCTestCase {

    func testAttentionSeparatesCurrentStateFromHistory() {
        let broken = HermesSystemComponent(name: "telegram", status: "disconnected")
        let healthy = HermesSystemComponent(name: "gateway", status: "running")
        let failing = JobRow(
            id: "j1", name: "Daily brief", prompt: "", schedule: "", enabled: true,
            lastStatus: "error", lastError: "boom", lastRun: Date(), nextRun: nil,
            profile: "radar-ia"
        )

        let items = EventDigest.attention(
            routines: [failing], components: [broken, healthy]
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.title == "Telegram" })
        XCTAssertTrue(items.contains { $0.title == "Daily brief" })
        // Sorted worst-first, so a status line that shows one shows the worst.
        XCTAssertEqual(items.first?.severity, .failure)
    }

    /// A healthy installation has nothing to report, and must not manufacture
    /// something so the screen has a row on it.
    func testHealthyInstallationHasNoAttentionItems() {
        let items = EventDigest.attention(
            routines: [
                JobRow(id: "j1", name: "Brief", prompt: "", schedule: "", enabled: true,
                       lastStatus: "ok", lastError: nil, lastRun: Date(), nextRun: nil,
                       profile: "default")
            ],
            components: [HermesSystemComponent(name: "gateway", status: "running")]
        )
        XCTAssertTrue(items.isEmpty)
    }

    /// Attention counts current state; the digest reports change. Both read the
    /// same snapshot, so they cannot contradict each other.
    func testAttentionAndDigestAgreeOnTheSameReading() {
        let component = HermesSystemComponent(name: "telegram", status: "disconnected")
        var marks = EventWatermarks()
        marks.primed = true
        marks.componentStatus["telegram"] = "connected"

        let changed = EventDigest.digest(routines: [], components: [component], since: marks)
        let current = EventDigest.attention(routines: [], components: [component])

        XCTAssertEqual(changed.events.map(\.kind), [.attention])
        XCTAssertEqual(current.map(\.kind), [.attention])
    }
}
