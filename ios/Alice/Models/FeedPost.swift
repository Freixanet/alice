import Foundation

/// A source a feed post cites, exactly as Alice's research surfaced it (`feed.py`'s registry).
struct FeedSource: Codable, Hashable, Sendable {
    var ref: String
    var title: String
    var url: URL

    /// The site, for the citation chip: "reuters.com".
    var host: String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What the person did with a post, as the server derives it from their events.
struct FeedViewerState: Codable, Hashable, Sendable {
    var loved = false
    var lovedAt: Date?
    var discussCount = 0
}

/// One post in Alice's editorial feed.
///
/// Written fresh by Alice from the person's brief (or, for the first run, fixed in the app:
/// `FeedSeed`). The body cites each claim inline with `[n]`, n being the source's position in
/// `sourceLinks`.
struct FeedPost: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var kicker: String
    var category: String
    var headline: String
    var body: String
    var sourceLinks: [FeedSource]
    var storyKey: String?
    var createdAt: Date
    /// When the person first opened it up. Kept on this phone only.
    var readAt: Date?
    var whyThis: String?
    var language: String?
    /// For a post drawn from the person's own connected services rather than the web: "mail", "calendar"…
    var basis: String?
    /// A task Alice offers to do about this post, in her words; shown as "Do it".
    var offer: String?
    var isSeeded = false
    var viewer = FeedViewerState()
    /// Hidden by the person; kept until the server has the delete, so an undo can bring it back.
    var deleted = false

    var loved: Bool { viewer.loved }
}

/// The run that writes posts, as the server reports it.
struct FeedGeneration: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case idle, queued, running, failed }

    var state: State = .idle
    var error: String?
    var finishedAt: Date?
    var pendingAfterRun = false

    var isActive: Bool { state == .queued || state == .running }
}

/// Something the person did with a post, waiting to reach the Mac. Retried with the same id,
/// which the server uses to apply it once.
struct FeedEvent: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case love, discuss, delete }

    var id: UUID
    var postID: String
    var kind: Kind
    /// For love and delete; a discuss has none.
    var on: Bool?
    var createdAt: Date
}

/// Everything the feed keeps on the phone: readable offline, and what has not reached the Mac yet.
struct FeedCache: Codable, Sendable {
    var posts: [FeedPost] = []
    var brief = ""
    var generation = FeedGeneration()
    var lastRevision: Int?
    var outbox: [FeedEvent] = []
    /// The intro posts were shown once; they are never shown again after being cleared.
    var seeded = false
    var syncedAt: Date?
}

// MARK: - Server payloads

/// `GET /feed` and `GET /feed/status`, as `feed.py` writes them (seconds since 1970).
struct FeedPayload: Decodable, Sendable {
    struct Source: Decodable, Sendable {
        var ref: String
        var title: String?
        var url: String
    }

    struct Viewer: Decodable, Sendable {
        var loved: Bool
        var lovedAt: Double?
        var discussCount: Int
    }

    struct Post: Decodable, Sendable {
        var id: String
        var kicker: String?
        var category: String?
        var headline: String
        var body: String
        var sources: [Source]
        var storyKey: String?
        var createdAt: Double
        var whyThis: String?
        var language: String?
        var basis: String?
        var offer: String?
        var viewerState: Viewer?
    }

    struct Brief: Decodable, Sendable { var text: String? }

    struct Generation: Decodable, Sendable {
        var state: String
        var error: String?
        var finishedAt: Double?
        var pendingAfterRun: Bool?
    }

    var revision: Int
    var posts: [Post]?
    var brief: Brief?
    var generation: Generation

    var feedGeneration: FeedGeneration {
        FeedGeneration(
            state: FeedGeneration.State(rawValue: generation.state) ?? .idle,
            error: (generation.error ?? "").isEmpty ? nil : generation.error,
            finishedAt: generation.finishedAt.map { Date(timeIntervalSince1970: $0) },
            pendingAfterRun: generation.pendingAfterRun ?? false
        )
    }

    /// The posts in the app's shape; a source whose URL does not parse is left out rather than guessed.
    var feedPosts: [FeedPost] {
        (posts ?? []).map { post in
            FeedPost(
                id: post.id, kicker: post.kicker ?? "", category: post.category ?? "",
                headline: post.headline, body: post.body,
                sourceLinks: post.sources.compactMap { source in
                    URL(string: source.url).map { FeedSource(ref: source.ref, title: source.title ?? "", url: $0) }
                },
                storyKey: post.storyKey,
                createdAt: Date(timeIntervalSince1970: post.createdAt),
                whyThis: post.whyThis, language: post.language,
                basis: post.basis, offer: post.offer,
                viewer: FeedViewerState(
                    loved: post.viewerState?.loved ?? false,
                    lovedAt: post.viewerState?.lovedAt.map { Date(timeIntervalSince1970: $0) },
                    discussCount: post.viewerState?.discussCount ?? 0
                )
            )
        }
    }
}

// MARK: - Merging

enum FeedMerge {
    /// The server's posts as the baseline, with what is still waiting in the outbox replayed on
    /// top in order. Nothing is unioned: an unlike the server already has is never undone here.
    /// `readAt` is the phone's own. A post the server no longer lists goes, unless a delete for it
    /// is still on its way (then it stays, hidden or restored as that event says).
    static func merge(
        server: [FeedPost], local: [FeedPost], outbox: [FeedEvent]
    ) -> [FeedPost] {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pendingDeletes = Set(outbox.filter { $0.kind == .delete }.map(\.postID))
        var merged = server.map { post -> FeedPost in
            var post = post
            post.readAt = localByID[post.id]?.readAt
            return post
        }
        let listed = Set(merged.map(\.id))
        for post in local where !post.isSeeded && !listed.contains(post.id) && pendingDeletes.contains(post.id) {
            merged.append(post)
        }
        merged = replay(outbox, on: merged)
        return merged.sorted { $0.createdAt > $1.createdAt }
    }

    /// Applies events to posts, oldest first.
    static func replay(_ events: [FeedEvent], on posts: [FeedPost]) -> [FeedPost] {
        var posts = posts
        for event in events.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let index = posts.firstIndex(where: { $0.id == event.postID }) else { continue }
            switch event.kind {
            case .love:
                let on = event.on ?? false
                posts[index].viewer.loved = on
                posts[index].viewer.lovedAt = on ? event.createdAt : nil
            case .delete:
                posts[index].deleted = event.on ?? false
            case .discuss:
                posts[index].viewer.discussCount += 1
            }
        }
        return posts
    }
}

// MARK: - First run

/// The posts a brand-new feed opens on: what Alice can do, in her own words. Fixed in the app,
/// drawn on nothing personal, never rewritten; deletable, and gone once real posts arrive.
enum FeedSeed {
    static let retireAfter = 3

    static func posts(now: Date = Date()) -> [FeedPost] {
        let items: [(String, String, String, String)] = [
            ("feed", String(localized: "feed.seed.feed.kicker"), String(localized: "feed.seed.feed.headline"),
             String(localized: "feed.seed.feed.body")),
            ("chat", String(localized: "feed.seed.chat.kicker"), String(localized: "feed.seed.chat.headline"),
             String(localized: "feed.seed.chat.body")),
            ("agents", String(localized: "feed.seed.agents.kicker"), String(localized: "feed.seed.agents.headline"),
             String(localized: "feed.seed.agents.body")),
            ("errands", String(localized: "feed.seed.errands.kicker"), String(localized: "feed.seed.errands.headline"),
             String(localized: "feed.seed.errands.body")),
            ("library", String(localized: "feed.seed.library.kicker"), String(localized: "feed.seed.library.headline"),
             String(localized: "feed.seed.library.body")),
        ]
        return items.enumerated().map { index, item in
            FeedPost(
                id: "seed-\(item.0)", kicker: item.1, category: "Alice", headline: item.2, body: item.3,
                sourceLinks: [], storyKey: nil,
                // In reading order, newest first.
                createdAt: now.addingTimeInterval(-Double(index)),
                whyThis: nil, language: nil, isSeeded: true
            )
        }
    }
}
