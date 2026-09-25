import Foundation

/// The bytes behind a media card, fetched once and kept for the session.
///
/// A bot's download lives on the Hermes machine; the card reaches it over the
/// authenticated dashboard connection, the same one the chat uses, so it works
/// from anywhere and never expires. When Hermes cannot serve it — the file was
/// moved, the dashboard is down, the connection has no file access — the web
/// mirror the bot gave (a cobalt tunnel, a CDN) is tried next. Playing from a
/// local file is what makes seeking, replay and saving reliable: a tunnel
/// stream has no length and no ranges, and AVPlayer needs both.
///
/// Every card of the same media shares one download: the chat redraws rows as
/// it scrolls, and a second copy of a 200 MB video is never the answer.
@MainActor
enum RichMediaLoader {
    enum Source: Equatable, Sendable {
        case hermes
        case mirror
    }

    struct Loaded: Equatable, Sendable {
        let file: URL
        let source: Source
    }

    /// How each place is reached. Injected so the fallback order and the
    /// wording of a failure can be checked without a Hermes.
    struct Fetchers {
        var hermes: @MainActor (_ path: String) async throws -> URL
        var mirror: @MainActor (_ url: URL, _ name: String) async throws -> URL
    }

    enum Failure: LocalizedError, Equatable {
        /// Neither a Hermes path nor a web address: nothing to fetch.
        case nowhere
        case hermes(String)
        case mirror(String)
        case both(hermes: String, mirror: String)

        var errorDescription: String? {
            switch self {
            case .nowhere:
                return "This file has no address Alice can reach."
            case let .hermes(reason):
                return reason
            case let .mirror(reason):
                return reason
            case let .both(hermes, mirror):
                return hermes + " " + mirror
            }
        }
    }

    private static var loaded: [String: Loaded] = [:]
    private static var inFlight: [String: Task<Loaded, Error>] = [:]

    /// The local file for `media`, downloading it if this session has not yet.
    static func load(_ media: RichMedia, with fetchers: Fetchers) async throws -> Loaded {
        let key = media.cacheKey
        if let hit = loaded[key] {
            if FileManager.default.fileExists(atPath: hit.file.path) { return hit }
            loaded[key] = nil
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let task = Task<Loaded, Error> { try await fetch(media, with: fetchers) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        loaded[key] = result
        return result
    }

    /// Already on the phone, without fetching.
    static func cached(_ media: RichMedia) -> Loaded? {
        guard let hit = loaded[media.cacheKey] else { return nil }
        guard FileManager.default.fileExists(atPath: hit.file.path) else {
            // iOS purged the file: forget it, so the next load fetches again.
            loaded[media.cacheKey] = nil
            return nil
        }
        return hit
    }

    /// Hermes first, the mirror second; each failure keeps its own words so
    /// the card can say what actually went wrong, not just "failed".
    static func fetch(_ media: RichMedia, with fetchers: Fetchers) async throws -> Loaded {
        var hermesFailure: String?
        if let path = media.hermesPath {
            do {
                return Loaded(file: try await fetchers.hermes(path), source: .hermes)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                hermesFailure = RemoteFileProblem.describe(error)
            }
        }
        guard let mirror = media.webURL else {
            if let hermesFailure { throw Failure.hermes(hermesFailure) }
            throw Failure.nowhere
        }
        do {
            return Loaded(file: try await fetchers.mirror(mirror, media.fileName), source: .mirror)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = mirrorProblem(error, mirror: mirror)
            if let hermesFailure { throw Failure.both(hermes: hermesFailure, mirror: reason) }
            throw Failure.mirror(reason)
        }
    }

    /// A download link's failure, said for the person reading the chat. A
    /// cobalt tunnel expires and only answers on its own network, and both
    /// arrive as generic transport errors.
    static func mirrorProblem(_ error: Error, mirror: URL) -> String {
        if case DashboardClient.Failure.unreadable = error {
            return "The download link has expired."
        }
        let code = (error as? URLError)?.code
        if code == .cannotFindHost || code == .cannotConnectToHost || code == .notConnectedToInternet
            || code == .timedOut || code == .networkConnectionLost || code == .dnsLookupFailed {
            return "The download link at \(RichLinks.domain(mirror)) can’t be reached from here."
        }
        return "The download link didn’t answer."
    }

    /// Fetchers backed by the connected Hermes: the dashboard's file API for
    /// its files, a plain download for a web mirror.
    static func fetchers(_ store: AppStore) -> Fetchers {
        Fetchers(
            hermes: { path in try await store.downloadHermesFilesystemFile(path: path).url },
            mirror: { url, name in try await store.downloadRemoteMedia(url: url, name: name).url }
        )
    }

    /// Forgets every download of this session. Tests only.
    static func reset() {
        loaded.removeAll()
        inFlight.removeAll()
    }
}
