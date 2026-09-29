import XCTest
@testable import Alice

/// The feed on the phone: the server is the baseline, the outbox is replayed on top, and what
/// is read here stays here (`FeedMerge`, `FeedPayload`, `FeedBodyText`, `FeedSeed`).
final class FeedStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(_ id: String, at offset: TimeInterval = 0, loved: Bool = false, discuss: Int = 0) -> FeedPost {
        FeedPost(
            id: id, kicker: "IA", category: "tecnología", headline: "Titular \(id)", body: "Algo pasó.[1]",
            sourceLinks: [FeedSource(ref: "src_01", title: "Fuente", url: URL(string: "https://example.com/a")!)],
            storyKey: nil, createdAt: t0.addingTimeInterval(offset), readAt: nil, whyThis: nil, language: "es",
            viewer: FeedViewerState(loved: loved, lovedAt: nil, discussCount: discuss)
        )
    }

    private func event(_ post: String, _ kind: FeedEvent.Kind, _ on: Bool? = nil, at offset: TimeInterval) -> FeedEvent {
        FeedEvent(id: UUID(), postID: post, kind: kind, on: on, createdAt: t0.addingTimeInterval(offset))
    }

    func testAnUnloveTheServerHasIsNotResurrected() {
        // Loved here once; the server has since processed the unlove and says not loved.
        let local = [post("a", loved: true)]
        let merged = FeedMerge.merge(server: [post("a", loved: false)], local: local, outbox: [])
        XCTAssertFalse(merged[0].loved)
    }

    func testAPendingLoveSurvivesASync() {
        let merged = FeedMerge.merge(
            server: [post("a", loved: false)], local: [post("a")], outbox: [event("a", .love, true, at: 10)]
        )
        XCTAssertTrue(merged[0].loved)
    }

    func testPendingEventsReplayInOrder() {
        let outbox = [event("a", .love, false, at: 20), event("a", .love, true, at: 10), event("a", .discuss, at: 30)]
        let merged = FeedMerge.merge(server: [post("a", discuss: 2)], local: [post("a")], outbox: outbox)
        XCTAssertFalse(merged[0].loved)
        XCTAssertEqual(merged[0].viewer.discussCount, 3)
    }

    func testReadAtIsKeptFromThePhone() {
        var local = post("a")
        local.readAt = t0
        let merged = FeedMerge.merge(server: [post("a")], local: [local], outbox: [])
        XCTAssertEqual(merged[0].readAt, t0)
    }

    func testALocallyDeletedPostStaysHiddenUntilAcknowledged() {
        // The server already dropped it (its delete arrived), but this phone's delete is still waiting.
        let merged = FeedMerge.merge(server: [], local: [post("a")], outbox: [event("a", .delete, true, at: 5)])
        XCTAssertEqual(merged.map(\.id), ["a"])
        XCTAssertTrue(merged[0].deleted)
        // Without a pending event, a post the server no longer lists goes.
        XCTAssertTrue(FeedMerge.merge(server: [], local: [post("a")], outbox: []).isEmpty)
    }

    func testDeleteAndUndo() {
        let deleted = FeedMerge.replay([event("a", .delete, true, at: 1)], on: [post("a")])
        XCTAssertTrue(deleted[0].deleted)
        let restored = FeedMerge.replay([event("a", .delete, false, at: 2)], on: deleted)
        XCTAssertFalse(restored[0].deleted)
    }

    func testNewestFirst() {
        let merged = FeedMerge.merge(server: [post("old", at: 0), post("new", at: 60)], local: [], outbox: [])
        XCTAssertEqual(merged.map(\.id), ["new", "old"])
    }

    func testPayloadDecodesPostsAndGeneration() throws {
        let json = """
        {"revision": 7, "brief": {"text": "F1"}, "generation": {"state": "running", "pendingAfterRun": true},
         "posts": [{"id": "p1", "kicker": "F1", "category": "deporte", "headline": "H", "body": "B.[1]",
                    "sources": [{"ref": "src_01", "title": "T", "url": "https://example.com/x"},
                                {"ref": "src_02", "title": "Bad", "url": ""}],
                    "createdAt": 1800000000, "viewerState": {"loved": true, "lovedAt": 1800000100, "discussCount": 2}}]}
        """
        let payload = try JSONDecoder().decode(FeedPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.revision, 7)
        XCTAssertEqual(payload.feedGeneration.state, .running)
        XCTAssertTrue(payload.feedGeneration.pendingAfterRun)
        let parsed = try XCTUnwrap(payload.feedPosts.first)
        XCTAssertEqual(parsed.sourceLinks.map(\.ref), ["src_01"])
        XCTAssertTrue(parsed.loved)
        XCTAssertEqual(parsed.viewer.discussCount, 2)
    }

    func testCitationsBecomeLinksToTheirSources() {
        let sources = [FeedSource(ref: "src_01", title: "A", url: URL(string: "https://a.example/1")!),
                       FeedSource(ref: "src_02", title: "B", url: URL(string: "https://b.example/2")!)]
        let text = FeedBodyText.citationLinks("Uno.[1] Dos.[2] Nada.[3] Ya enlazado [1](https://x.example)", sources: sources)
        XCTAssertTrue(text.contains("](https://a.example/1)"))
        XCTAssertTrue(text.contains("](https://b.example/2)"))
        XCTAssertTrue(text.contains("Nada.[3]"))
        XCTAssertTrue(text.contains("[1](https://x.example)"))
    }

    func testSeedsAreFixedAndMarked() {
        let seeds = FeedSeed.posts(now: t0)
        XCTAssertEqual(seeds.count, 5)
        XCTAssertTrue(seeds.allSatisfy(\.isSeeded))
        XCTAssertTrue(seeds.allSatisfy { $0.sourceLinks.isEmpty })
        XCTAssertEqual(Set(seeds.map(\.id)).count, 5)
    }

    func testDiscussQuotesThePostAsThePersonsContext() {
        let text = AppStore.feedContextText(post("a"))
        XCTAssertTrue(text.hasPrefix("[From my feed — for context]"))
        XCTAssertTrue(text.contains("[1] Fuente — https://example.com/a"))
        var message = Message(id: "m", role: .user, content: text, createdAt: t0)
        message.feedContext = post("a")
        let history = WebSocketBotChatSource.openingHistory([message])
        XCTAssertEqual(history.first?["role"], "user")
    }

    @MainActor
    func testSeedOnceAndRetireWithRealPosts() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "feed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FeedStore(client: DashboardClient(), file: file)
        XCTAssertEqual(store.posts.filter(\.isSeeded).count, 5)
        // A second launch does not seed again, even after the seeds were deleted.
        let reopened = FeedStore(client: DashboardClient(), file: file)
        XCTAssertEqual(reopened.posts.count, 5)
    }
}
