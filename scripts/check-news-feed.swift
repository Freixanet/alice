import Foundation

@main struct FeedChecks {
    @MainActor static func main() throws {
        let source = NewsSource.catalogue[0]
        let fixture = """
        <rss version="2.0"><channel><item><title>Science &amp; culture</title>
        <link>https://example.com/story?utm_source=rss</link>
        <description><![CDATA[<p>A sourced excerpt.</p>]]></description>
        <pubDate>Sun, 27 Sep 2026 10:00:00 +0000</pubDate><category>Research</category>
        </item><item><title>Unsafe</title><link>javascript:alert(1)</link></item></channel></rss>
        """
        let posts = try NewsRSSParser(source: source).parse(Data(fixture.utf8))
        precondition(posts.count == 1 && posts.allSatisfy { !$0.title.isEmpty && $0.url.scheme == "https" })
        precondition(posts.allSatisfy { $0.published != nil })
        precondition(NewsRSSParser.safeURL("javascript:alert(1)") == nil)
        precondition(NewsRSSParser.safeURL("https://user:secret@example.com") == nil)
        precondition(NewsRSSParser.safeURL("https://example.com/story?utm_source=x#part")?.absoluteString == "https://example.com/story")
        do { _ = try NewsRSSParser(source: source).parse(Data("<html/>".utf8)); preconditionFailure("Non-RSS accepted") } catch {}
        let now = Date()
        func post(_ id: String, _ source: String, _ topic: String) -> NewsPost {
            NewsPost(url: URL(string: "https://example.com/" + id)!, sourceID: source, source: source,
                     topic: topic, title: id, excerpt: "", published: now, image: nil, tags: [])
        }
        let a = post("a", "one", "Science"), b = post("b", "two", "Culture")
        var archive = NewsArchive()
        archive.interests = ["Culture"]
        precondition(NewsRanking.order([a,b], archive: archive).first?.id == b.id)
        archive.feedback[b.id] = NewsFeedback(features: b.features, vote: -1)
        precondition(NewsRanking.order([a,b], archive: archive).map(\.id) == [a.id])
        archive = NewsArchive()
        archive.feedback[a.id] = NewsFeedback(features: a.features, vote: 1, saved: true)
        precondition(NewsRanking.order([a,b], archive: archive).first?.id == a.id)
        archive.mutedSources = ["one"]
        precondition(NewsRanking.order([a,b,a], archive: archive).map(\.id) == [b.id])
        let suite = "alice.feed.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NewsFeedStore(defaults: defaults)
        store.interest("Ciencia", enabled: true)
        precondition(NewsFeedStore(defaults: defaults).archive.interests.contains("Ciencia"))
        let bad = Data("unreadable".utf8)
        defaults.set(bad, forKey: "alice.newsFeed.v1")
        let broken = NewsFeedStore(defaults: defaults)
        broken.interest("Cultura", enabled: true)
        precondition(broken.storageFailure && defaults.data(forKey: "alice.newsFeed.v1") == bad)
        print("PASS: RSS publisher fixture, dates, URL normalization, unsafe URLs, malformed feed, interest ranking, negative feedback, saves, deduplication, source mute, persistence, corrupt archive preservation")
    }
}
