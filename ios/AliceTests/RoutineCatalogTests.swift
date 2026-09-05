import XCTest
@testable import Alice

/// The data layer behind both routine screens.
///
/// The bug these cover: the Jobs screen read the gateway, which serves one
/// profile, while a bot's own screen read the dashboard, which sees all of
/// them. A routine belonging to a named profile was therefore visible on one
/// screen and missing from the other.
final class RoutineCatalogTests: XCTestCase {
    /// Counts its reads, so a test can prove two screens share one source.
    private actor Across: CrossProfileRoutines {
        private let grouped: [String: [JobRow]]
        private(set) var reads = 0

        init(_ grouped: [String: [JobRow]]) { self.grouped = grouped }

        func allRoutines() async throws -> [String: [JobRow]] {
            reads += 1
            return grouped
        }
    }

    private struct FailingAcross: CrossProfileRoutines {
        let error: Error
        func allRoutines() async throws -> [String: [JobRow]] { throw error }
    }

    private struct Gateway: SingleProfileRoutines {
        var rows: [JobRow] = []
        func profileJobs() async throws -> [JobRow] { rows }
    }

    private enum Unreachable: Error { case noAnswer }

    private static func job(_ id: String, _ name: String = "routine") -> JobRow {
        JobRow(
            id: id, name: name, prompt: "", schedule: "daily at 10am",
            enabled: true, lastStatus: nil, lastError: nil,
            lastRun: nil, nextRun: nil
        )
    }

    private static let radarIA = job("c3cf075a5b68", "Radar IA — informe diario")
    private static let chollo = job("aa11bb22cc33", "Chollometro — novedades")

    private static func catalog(
        _ across: CrossProfileRoutines?, gateway: Gateway = Gateway()
    ) -> RoutineCatalog {
        RoutineCatalog(across: across, gateway: gateway)
    }

    // A. Global Jobs sees every profile, each routine once.
    func testGlobalJobsReturnsEveryProfilesRoutineExactlyOnce() async throws {
        let listing = try await Self.catalog(
            Across(["radar-ia": [Self.radarIA], "chollometro": [Self.chollo]])
        ).everything()

        XCTAssertEqual(listing.scope, .allProfiles)
        XCTAssertEqual(listing.rows.map(\.id), ["aa11bb22cc33", "c3cf075a5b68"])
    }

    // B. A bot gets only its own.
    func testRoutinesForRadarIAReturnsOnlyItsOwn() async throws {
        let rows = try await Self.catalog(
            Across(["radar-ia": [Self.radarIA], "chollometro": [Self.chollo]])
        ).routines(for: "radar-ia")

        XCTAssertEqual(rows.map(\.id), ["c3cf075a5b68"])
    }

    // C. Both screens read the same source, so they cannot disagree.
    func testBothScreensReadTheSameSource() async throws {
        let across = Across(["radar-ia": [Self.radarIA], "chollometro": [Self.chollo]])
        let catalog = Self.catalog(across)

        let everything = try await catalog.everything()
        let radar = try await catalog.routines(for: "radar-ia")

        let reads = await across.reads
        XCTAssertEqual(reads, 2, "both paths must go through the cross-profile reader")
        XCTAssertTrue(
            Set(radar.map(\.id)).isSubset(of: Set(everything.rows.map(\.id))),
            "a bot's routines must be a slice of the global list, not a second opinion"
        )
    }

    // D. A dashboard that fails is a failure, never an empty list.
    func testDashboardFailuresPropagateRatherThanReadingAsEmpty() async {
        let failures: [Error] = [
            DashboardClient.Failure.http(401, detail: "Authentication required"),
            DashboardClient.Failure.http(404, detail: "not found"),
            Unreachable.noAnswer,
        ]

        for failure in failures {
            let catalog = Self.catalog(
                FailingAcross(error: failure),
                gateway: Gateway(rows: [Self.radarIA])
            )
            do {
                let listing = try await catalog.everything()
                XCTFail("swallowed \(failure) into \(listing.rows.count) rows")
            } catch {
                // The gateway's own list must not stand in for the global one
                // either: that is how a partial answer becomes a wrong one.
            }
        }
    }

    // E. A genuinely empty agent reads as empty.
    func testATrulyEmptyAgentReturnsAnEmptyList() async throws {
        let listing = try await Self.catalog(Across([:])).everything()

        XCTAssertEqual(listing.scope, .allProfiles)
        XCTAssertTrue(listing.rows.isEmpty)
    }

    // F. Legacy extras do not duplicate a row.
    func testARowRepeatedAcrossProfilesIsDrawnOnce() async throws {
        let listing = try await Self.catalog(
            Across(["radar-ia": [Self.radarIA], "default": [Self.radarIA]])
        ).everything()

        XCTAssertEqual(listing.rows.map(\.id), ["c3cf075a5b68"])
    }

    // MARK: - One bot's routines, with no cross-profile source
    //
    // The global list may fall back to the gateway, because the screen labels
    // that partial. One bot's list may not: a gateway serving another profile
    // cannot tell an empty bot from a bot it has never heard of.

    /// The real path, not `RoutineState` in isolation: with no dashboard,
    /// asking for one bot's routines must throw.
    func testOneBotsRoutinesThrowWithoutACrossProfileSource() async {
        let catalog = Self.catalog(nil, gateway: Gateway(rows: [Self.radarIA]))

        do {
            let rows = try await catalog.routines(for: "radar-ia")
            XCTFail("returned \(rows.count) rows instead of failing")
        } catch DashboardClient.Failure.notConfigured {
            // What the screen needs to hear: there is no source, not no work.
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// The same call as the screen makes it. This is the assertion the earlier
    /// `RoutineState`-only test could not make: the catalog used to answer []
    /// successfully, so `resolving` saw a success and BotDetail drew
    /// "No routines yet" for a dashboard that was never configured.
    func testThatPathResolvesToFailedRatherThanAnEmptyBot() async {
        let catalog = Self.catalog(nil, gateway: Gateway(rows: [Self.radarIA]))

        let state = await RoutineState.resolving {
            try await catalog.routines(for: "radar-ia")
        }

        XCTAssertFalse(state.isEmptyAnswer, "an unconfigured dashboard is not an empty bot")
        XCTAssertNotNil(state.failure)
    }

    /// A configured dashboard that really answers nothing still reads as
    /// empty — the one case that is allowed to.
    func testAConfiguredDashboardWithNoRoutinesStillResolvesToEmpty() async {
        let catalog = Self.catalog(Across(["radar-ia": []]))

        let state = await RoutineState.resolving {
            try await catalog.routines(for: "radar-ia")
        }

        XCTAssertEqual(state, .loaded([]))
        XCTAssertTrue(state.isEmptyAnswer)
    }

    /// And the real routine still arrives through the same path.
    func testTheRealRoutineArrivesThroughTheSamePath() async {
        let catalog = Self.catalog(
            Across(["radar-ia": [Self.radarIA], "chollometro": [Self.chollo]])
        )

        let state = await RoutineState.resolving {
            try await catalog.routines(for: "radar-ia")
        }

        XCTAssertEqual(state.rows.map(\.id), ["c3cf075a5b68"])
    }

    /// With no dashboard there is no cross-profile source, and the answer says
    /// so rather than passing one gateway's profile off as the whole agent.
    func testWithoutADashboardTheListingIsMarkedPartial() async throws {
        let listing = try await Self.catalog(
            nil, gateway: Gateway(rows: [Self.radarIA])
        ).everything()

        XCTAssertEqual(listing.scope, .oneGatewayProfile)
        XCTAssertEqual(listing.rows.map(\.id), ["c3cf075a5b68"])
    }
}
