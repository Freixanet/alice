import Foundation

/// How much of the agent a routine listing could actually see.
///
/// The gateway serves one profile. Its job list is therefore never the whole
/// picture, and presenting it as one is how a bot's routine turns into
/// "No scheduled jobs" on a screen that promises every job there is. The scope
/// travels with the rows so a partial answer cannot pass for a complete one.
enum RoutineScope: Equatable {
    /// Every profile, from the dashboard's cross-profile listing.
    case allProfiles
    /// One gateway's own profile. Incomplete by construction.
    case oneGatewayProfile
}

struct RoutineListing: Equatable {
    var rows: [JobRow]
    var scope: RoutineScope
}

/// The cross-profile listing — `DashboardClient` in the app, a stub in tests.
protocol CrossProfileRoutines: Sendable {
    func allRoutines() async throws -> [String: [JobRow]]
}

/// The gateway's own profile, used only as a declared-partial fallback.
protocol SingleProfileRoutines: Sendable {
    func profileJobs() async throws -> [JobRow]
}

/// One reader behind both the Jobs screen and a bot's own routines.
///
/// They used to disagree: the bot read the dashboard and Jobs read the
/// gateway, so a routine belonging to a named profile appeared on one screen
/// and not the other. Both go through `allRoutines()` now, and a bot's list is
/// a slice of the same dictionary rather than a second request answered by a
/// different server.
struct RoutineCatalog {
    /// Absent when no dashboard is configured; there is then no source that
    /// can see across profiles at all.
    var across: CrossProfileRoutines?
    var gateway: SingleProfileRoutines

    /// Every routine the app can see, and how much that is.
    ///
    /// Errors are not caught. A dashboard that answers 401, 404 or nothing at
    /// all must reach the screen as a failure — swallowing it here would draw
    /// "No scheduled jobs" over an agent that has plenty.
    func everything() async throws -> RoutineListing {
        guard let across else {
            return RoutineListing(
                rows: try await gateway.profileJobs(), scope: .oneGatewayProfile
            )
        }
        return RoutineListing(
            rows: Self.flatten(try await across.allRoutines()), scope: .allProfiles
        )
    }

    /// One bot's routines, from the same dictionary the Jobs screen flattens.
    func routines(for profile: String) async throws -> [JobRow] {
        guard let across else { return [] }
        return try await across.allRoutines()[profile] ?? []
    }

    /// The grouped listing as one list.
    ///
    /// Ordered by profile so the screen does not reshuffle between reads, and
    /// keyed by id on the way through: `profile=all` concatenates one store per
    /// profile, and a row that turned up under two of them would otherwise be
    /// drawn twice.
    static func flatten(_ grouped: [String: [JobRow]]) -> [JobRow] {
        var seen = Set<String>()
        var rows: [JobRow] = []
        for profile in grouped.keys.sorted() {
            for job in grouped[profile] ?? [] where seen.insert(job.id).inserted {
                rows.append(job)
            }
        }
        return rows
    }
}

/// Binds the gateway's job listing, which needs the manifest, to the plain
/// call the catalog makes.
struct GatewayRoutines: SingleProfileRoutines {
    let client: HermesClient
    let manifest: HermesClient.Manifest?

    func profileJobs() async throws -> [JobRow] {
        try await client.jobs(manifest)
    }
}

extension DashboardClient: CrossProfileRoutines {}
