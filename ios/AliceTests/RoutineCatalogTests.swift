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

    private static func job(
        _ id: String, _ name: String = "routine", profile: String? = nil
    ) -> JobRow {
        JobRow(
            id: id, name: name, prompt: "", schedule: "daily at 10am",
            enabled: true, lastStatus: nil, lastError: nil,
            lastRun: nil, nextRun: nil, profile: profile
        )
    }

    private static let radarIA = job(
        "c3cf075a5b68", "Radar IA — informe diario", profile: "radar-ia"
    )
    private static let chollo = job(
        "aa11bb22cc33", "Chollometro — novedades", profile: "chollometro"
    )

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

    // F. A store enumerated twice within one profile is drawn once, but a
    // shared id ACROSS profiles is two different routines and both survive.
    //
    // This replaces a test that asserted the opposite. Ids are
    // `uuid.uuid4().hex[:12]` with no collision check and one store per
    // profile home, so nothing in the agent makes them unique between
    // profiles — the earlier test had turned that assumption into a contract,
    // and the behaviour it fixed would delete a real routine.
    func testARepeatedRowWithinOneProfileIsDrawnOnce() async throws {
        let listing = try await Self.catalog(
            Across(["radar-ia": [Self.radarIA, Self.radarIA]])
        ).everything()

        XCTAssertEqual(listing.rows.map(\.id), ["c3cf075a5b68"])
    }

    func testTheSameIdInTwoProfilesKeepsBothRoutines() async throws {
        var twin = Self.chollo
        twin = JobRow(
            id: Self.radarIA.id, name: "Chollometro — novedades", prompt: "",
            schedule: "daily at 10am", enabled: true, lastStatus: nil,
            lastError: nil, lastRun: nil, nextRun: nil, profile: "chollometro"
        )

        let listing = try await Self.catalog(
            Across(["radar-ia": [Self.radarIA], "chollometro": [twin]])
        ).everything()

        XCTAssertEqual(listing.rows.count, 2, "a real routine was deduplicated away")
        XCTAssertEqual(
            Set(listing.rows.map(\.listIdentity)),
            ["radar-ia/c3cf075a5b68", "chollometro/c3cf075a5b68"],
            "and the list still has two distinct identities to draw"
        )
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
