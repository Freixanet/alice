import Foundation
import Observation

struct NewsSource: Identifiable, Sendable {
    let id: String
    let name: String
    let topic: String
    let address: String

    static let catalogue: [NewsSource] = [
        NewsSource(id: "ep-tech", name: "EL PAÍS", topic: "Tecnología", address: "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/tecnologia/portada"),
        NewsSource(id: "ep-science", name: "EL PAÍS", topic: "Ciencia", address: "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/ciencia/portada"),
        NewsSource(id: "ep-business", name: "EL PAÍS", topic: "Economía", address: "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/economia/portada"),
        NewsSource(id: "ep-culture", name: "EL PAÍS", topic: "Cultura", address: "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/cultura/portada"),
        NewsSource(id: "ep-world", name: "EL PAÍS", topic: "Actualidad", address: "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/internacional/portada"),
        NewsSource(id: "bbc-tech", name: "BBC News", topic: "Tecnología", address: "https://feeds.bbci.co.uk/news/technology/rss.xml"),
        NewsSource(id: "bbc-world", name: "BBC News", topic: "Actualidad", address: "https://feeds.bbci.co.uk/news/world/rss.xml"),
        NewsSource(id: "nasa", name: "NASA", topic: "Ciencia", address: "https://www.nasa.gov/feed/")
    ]
    static var topics: [String] { Array(Set(catalogue.map(\.topic))).sorted() }
}

struct NewsPost: Codable, Identifiable, Sendable {
    var id: String { url.absoluteString }
    let url: URL
    let sourceID: String
    let source: String
    let topic: String
    let title: String
    let excerpt: String
    let published: Date?
    let image: URL?
    let tags: [String]
    var features: [String] { ["topic:" + topic] + tags.prefix(6).map { "tag:" + $0.lowercased() } }
}

struct NewsFeedback: Codable, Sendable {
    let features: [String]
    var vote: Int = 0
    var saved = false
    var opened = false
    var at = Date()
}

struct NewsArchive: Codable {
    var posts: [NewsPost] = []
    var feedback: [String: NewsFeedback] = [:]
    var interests: Set<String> = []
    var mutedSources: Set<String> = []
    var refreshed: Date?
}

/// Bounded relevance signals; explicit feedback outweighs opens. Recency and
/// a greedy diversity penalty keep a single learned topic from taking over.
enum NewsRanking {
    static func weights(_ feedback: [String: NewsFeedback], now: Date) -> [String: Double] {
        var result: [String: Double] = [:]
        for value in feedback.values {
            let age = max(0, now.timeIntervalSince(value.at) / 86_400)
            let signal = (Double(value.vote) * 2 + (value.saved ? 2 : 0) + (value.opened ? 0.2 : 0)) * pow(0.5, age / 30)
            for key in value.features { result[key, default: 0] += signal }
        }
        return result.mapValues { max(-4, min(4, $0)) }
    }

    static func order(_ posts: [NewsPost], archive: NewsArchive, now: Date = Date()) -> [NewsPost] {
        let learned = weights(archive.feedback, now: now)
        var seen = Set<String>()
        let eligible = posts.filter {
            !archive.mutedSources.contains($0.sourceID) && archive.feedback[$0.id]?.vote != -1 && seen.insert($0.id).inserted
        }
        var candidates: [(NewsPost, Double)] = eligible.map { post in
            let age = max(0, now.timeIntervalSince(post.published ?? now.addingTimeInterval(-7 * 86_400)) / 86_400)
            let relevance = post.features.reduce(0.0) { $0 + (learned[$1] ?? 0) } / Double(max(1, post.features.count))
            let freshness: Double = 3 * exp(-age / 3)
            let interest: Double = archive.interests.contains(post.topic) ? 2 : 0
            let opened: Double = archive.feedback[post.id]?.opened == true ? 0.7 : 0
            let score: Double = freshness + relevance + interest - opened
            return (post, score)
        }
        candidates.sort { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        var output: [NewsPost] = []
        while !candidates.isEmpty {
            let recent = output.suffix(4)
            let index = candidates.indices.max { left, right in
                func adjusted(_ index: Int) -> Double {
                    let candidate = candidates[index]
                    return candidate.1 - Double(recent.filter { $0.source == candidate.0.source }.count) * 1.2
                        - Double(recent.filter { $0.topic == candidate.0.topic }.count) * 0.8
                }
                return adjusted(left) < adjusted(right)
            }!
            output.append(candidates.remove(at: index).0)
        }
        return output
    }
}

/// Reads publisher-provided headlines/excerpts, never fetches full articles.
final class NewsRSSParser: NSObject, XMLParserDelegate {
    private let source: NewsSource
    private var depth = 0
    private var itemDepth: Int?
    private var field: String?
    private var buffer = ""
    private var values: [String: String] = [:]
    private var tags: [String] = []
    private var image: URL?
    private var posts: [NewsPost] = []
    private var isRSS = false

    init(source: NewsSource) { self.source = source }

    func parse(_ data: Data) throws -> [NewsPost] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), isRSS else { throw URLError(.cannotParseResponse) }
        return posts
    }

    static func safeURL(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && $0.name != "fbclid" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.url
    }

    static func plain(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">") ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if element == "rss" { isRSS = true }
        if element == "item" {
            itemDepth = depth; values = [:]; tags = []; image = nil
        } else if let start = itemDepth {
            if depth == start + 1 && ["title", "link", "description", "pubDate", "category"].contains(element) {
                field = element; buffer = ""
            }
            if image == nil, ["media:content", "media:thumbnail", "enclosure"].contains(element),
               attributes["medium"] == "image" || attributes["type"]?.hasPrefix("image/") == true || element == "media:thumbnail" {
                image = Self.safeURL(attributes["url"] ?? "")
            }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if field != nil { buffer += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if field != nil { buffer += String(decoding: CDATABlock, as: UTF8.self) }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if let start = itemDepth, depth == start + 1, field == element {
            if element == "category" { tags.append(Self.plain(buffer)) } else { values[element] = buffer }
            field = nil
        }
        if element == "item", itemDepth == depth {
            defer { itemDepth = nil; field = nil }
            guard posts.count < 60, let url = Self.safeURL(values["link"] ?? "") else { return }
            let title = Self.plain(values["title"] ?? "")
            guard !title.isEmpty else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            let date = formatter.date(from: values["pubDate"] ?? "")
            posts.append(NewsPost(url: url, sourceID: source.id, source: source.name, topic: source.topic,
                                  title: String(title.prefix(400)), excerpt: String(Self.plain(values["description"] ?? "").prefix(500)),
                                  published: date, image: image, tags: Array(tags.prefix(8))))
        }
    }
}

@MainActor @Observable
final class NewsFeedStore {
    static let shared = NewsFeedStore()
    private let key = "alice.newsFeed.v1"
    private let defaults: UserDefaults
    private(set) var archive = NewsArchive()
    private(set) var timeline: [NewsPost] = []
    private(set) var loading = false
    private(set) var failure: String?
    private(set) var storageFailure = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do { archive = try JSONDecoder().decode(NewsArchive.self, from: data) }
            catch { storageFailure = true }
        }
        rebuild()
    }

    func rebuild() { timeline = NewsRanking.order(archive.posts, archive: archive) }
    var saved: [NewsPost] { archive.posts.filter { archive.feedback[$0.id]?.saved == true } }

    func respond(_ post: NewsPost, vote: Int? = nil, save: Bool? = nil, opened: Bool = false) {
        guard !storageFailure else { return }
        let previous = archive.feedback[post.id]
        var feedback = NewsFeedback(features: post.features, vote: previous?.vote ?? 0,
                                    saved: previous?.saved ?? false, opened: previous?.opened ?? false,
                                    at: previous?.at ?? Date())
        if let vote { feedback.vote = feedback.vote == vote ? 0 : vote }
        if let save { feedback.saved = save }
        if opened { feedback.opened = true }
        if vote != nil || save != nil || (opened && previous?.opened != true) { feedback.at = Date() }
        archive.feedback[post.id] = feedback
        // Keep scroll position stable for positive feedback; apply learning on refresh.
        if feedback.vote == -1 { timeline.removeAll { $0.id == post.id } }
        persist()
    }
    func interest(_ topic: String, enabled: Bool) {
        guard !storageFailure else { return }
        if enabled { archive.interests.insert(topic) } else { archive.interests.remove(topic) }
        rebuild(); persist()
    }
    func source(_ id: String, enabled: Bool) {
        guard !storageFailure else { return }
        if enabled { archive.mutedSources.remove(id) } else { archive.mutedSources.insert(id) }
        rebuild(); persist()
    }
    func resetLearning() {
        guard !storageFailure else { return }
        archive.feedback = archive.feedback.filter { $0.value.saved }.mapValues {
            NewsFeedback(features: [], saved: $0.saved)
        }
        archive.interests = []; rebuild(); persist()
    }
    private func persist() {
        guard !storageFailure else { return }
        // Bound reading history while keeping saves until explicitly removed.
        let saved = archive.feedback.filter { $0.value.saved }
        let latest = archive.feedback.filter { !$0.value.saved }.sorted { $0.value.at > $1.value.at }.prefix(1000)
        archive.feedback = saved.merging(Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value) })) { first, _ in first }
        do { defaults.set(try JSONEncoder().encode(archive), forKey: key) }
        catch { storageFailure = true }
    }
    func refresh(force: Bool = false) async {
        guard !loading, !ProcessInfo.processInfo.arguments.contains("-visualReview") else { return }
        if !force, let at = archive.refreshed, Date().timeIntervalSince(at) < 900 { return }
        loading = true; failure = nil
        defer { loading = false }
        let sources = NewsSource.catalogue.filter { !archive.mutedSources.contains($0.id) }
        var fetched: [NewsPost] = []
        var failed: [String] = []
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        await withTaskGroup(of: (String, [NewsPost]?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let (bytes, response) = try await session.bytes(from: URL(string: source.address)!)
                        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                              response.url?.scheme == "https", response.expectedContentLength <= 2_000_000 else { return (source.id, nil) }
                        var data = Data()
                        for try await byte in bytes {
                            if data.count >= 2_000_000 { return (source.id, nil) }
                            data.append(byte)
                        }
                        return (source.id, try NewsRSSParser(source: source).parse(data))
                    } catch { return (source.id, nil) }
                }
            }
            for await (id, posts) in group {
                if let posts { fetched += posts } else { failed.append(id) }
            }
        }
        if Task.isCancelled { return }
        let retained = archive.posts.filter { failed.contains($0.sourceID) || archive.feedback[$0.id]?.saved == true }
        var seen = Set<String>()
        archive.posts = (fetched + retained).filter { seen.insert($0.id).inserted }
        if failed.count < sources.count { archive.refreshed = Date() }
        if !failed.isEmpty { failure = "No se pudieron actualizar \(failed.count) fuentes. Conservamos las publicaciones disponibles." }
        rebuild(); persist()
    }
}
