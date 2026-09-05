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
/// They used to disagree by construction: the bot read the dashboard and Jobs
/// read the gateway, so a routine belonging to a named profile appeared on one
/// screen and not the other. Both go through `allRoutines()` now.
///
/// This buys one source and one contract, not one snapshot. Each screen still
/// makes its own read, and the agent can change between them — a routine added
/// after Jobs loaded will be on the bot's screen and not on the list behind
/// it, until that list is refreshed. That is ordinary staleness, and cheaper
/// to accept than a shared cache would be; what it is not is the two screens
/// disagreeing about what the same answer meant.
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
    ///
    /// With no cross-profile source there is no answer to give. The gateway
    /// cannot stand in the way it does for the global list: it serves one
    /// profile, so it cannot say whether *this* bot has no routines or whether
    /// it simply is not the profile being served. Returning [] here said the
    /// first when only the second was known, which is the whole defect
    /// `RoutineState` exists to prevent — and it prevented nothing, because
    /// the empty list arrived as a success.
    func routines(for profile: String) async throws -> [JobRow] {
        guard let across else { throw DashboardClient.Failure.notConfigured }
        return try await across.allRoutines()[profile] ?? []
    }

    /// The grouped listing as one list.
    ///
    /// Ordered by profile so the screen does not reshuffle between reads.
    ///
    /// Deduplication is per profile, never across them. Ids are
    /// `uuid.uuid4().hex[:12]` — forty-eight bits, generated with no collision
    /// check, in a separate store per profile home — so nothing in the agent
    /// makes them unique between profiles. Keying the whole list on id alone
    /// would silently delete one bot's real routine to keep another's, which
    /// is a worse failure than drawing an unlikely duplicate.
    static func flatten(_ grouped: [String: [JobRow]]) -> [JobRow] {
        var rows: [JobRow] = []
        for profile in grouped.keys.sorted() {
            var seen = Set<String>()
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

/// A remote routine list, with failure kept distinct from emptiness.
///
/// `(try? await …) ?? []` collapses every way a read can go wrong into the
/// same value a healthy agent with no routines returns, and the screen then
/// says "No routines yet" over a dashboard that is unconfigured, refusing the
/// session, or simply not answering. Those are four different things and only
/// one of them is news about the bot.
enum RoutineState: Equatable {
    case loading
    /// The agent answered. An empty array here means it really has none.
    case loaded([JobRow])
    case failed(String)

    /// Runs a read and keeps what happened.
    ///
    /// The only place the result of a routine read is turned into state, so
    /// there is one answer to "what counts as no routines" rather than one per
    /// call site.
    static func resolving(
        isolation: isolated (any Actor)? = #isolation,
        _ read: () async throws -> [JobRow],
        describe: (Error) -> String = { ($0 as? LocalizedError)?.errorDescription
            ?? "The dashboard did not answer." }
    ) async -> RoutineState {
        do {
            return .loaded(try await read())
        } catch {
            return .failed(describe(error))
        }
    }

    /// True only for a successful read that returned nothing.
    var isEmptyAnswer: Bool {
        if case let .loaded(rows) = self { return rows.isEmpty }
        return false
    }

    var rows: [JobRow] {
        if case let .loaded(rows) = self { return rows }
        return []
    }

    var failure: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
