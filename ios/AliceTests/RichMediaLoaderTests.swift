import XCTest
@testable import Alice

/// Where a media card's bytes come from, and what it says when they do not.
@MainActor
final class RichMediaLoaderTests: XCTestCase {
    private let tunnel = URL(string: "http://mac.local:9000/tunnel?id=1")!

    private func hermesMedia(mirror: Bool = true) -> RichMedia {
        RichMedia(
            title: "clip.mp4", url: mirror ? tunnel : URL(string: "alice://file?path=/w/clip.mp4")!,
            kind: .video, hermesPath: "/w/clip.mp4"
        )
    }

    private func temporaryFile(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        return url
    }

    override func setUp() async throws {
        try await super.setUp()
        RichMediaLoader.reset()
    }

    func testHermesIsAskedFirstAndTheMirrorIsLeftAlone() async throws {
        let local = temporaryFile("clip.mp4")
        var mirrorAsked = false
        let fetchers = RichMediaLoader.Fetchers(
            hermes: { path in
                XCTAssertEqual(path, "/w/clip.mp4")
                return local
            },
            mirror: { _, _ in
                mirrorAsked = true
                return local
            }
        )
        let loaded = try await RichMediaLoader.load(hermesMedia(), with: fetchers)
        XCTAssertEqual(loaded, .init(file: local, source: .hermes))
        XCTAssertFalse(mirrorAsked)
    }

    func testTheMirrorIsTriedWhenHermesCannotServeTheFile() async throws {
        let local = temporaryFile("clip.mp4")
        let fetchers = RichMediaLoader.Fetchers(
            hermes: { _ in throw DashboardClient.Failure.http(404, detail: "missing") },
            mirror: { url, name in
                XCTAssertEqual(url, self.tunnel)
                XCTAssertEqual(name, "clip.mp4")
                return local
            }
        )
        let loaded = try await RichMediaLoader.load(hermesMedia(), with: fetchers)
        XCTAssertEqual(loaded.source, .mirror)
    }

    func testBothFailuresAreSaidInPlainWords() async {
        let fetchers = RichMediaLoader.Fetchers(
            hermes: { _ in throw DashboardClient.Failure.http(404, detail: "missing") },
            mirror: { _, _ in throw DashboardClient.Failure.unreadable }
        )
        do {
            _ = try await RichMediaLoader.load(hermesMedia(), with: fetchers)
            XCTFail("expected a failure")
        } catch {
            let said = error.localizedDescription
            XCTAssertTrue(said.contains("isn’t there any more"), said)
            XCTAssertTrue(said.contains("expired"), said)
        }
    }

    func testAnUnreachableMirrorNamesItsHost() {
        let error = URLError(.cannotFindHost)
        XCTAssertEqual(
            RichMediaLoader.mirrorProblem(error, mirror: tunnel),
            "The download link at mac.local can’t be reached from here."
        )
    }

    func testAHermesOnlyFileWithNoMirrorReportsTheHermesReason() async {
        let fetchers = RichMediaLoader.Fetchers(
            hermes: { _ in throw DashboardClient.Failure.http(403, detail: "private") },
            mirror: { _, _ in XCTFail("no mirror to try"); throw DashboardClient.Failure.unreadable }
        )
        do {
            _ = try await RichMediaLoader.load(hermesMedia(mirror: false), with: fetchers)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? RichMediaLoader.Failure,
                           .hermes("This file is private, so Alice doesn’t open it."))
        }
    }

    func testAWebOnlyMediaSkipsHermesEntirely() async throws {
        let local = temporaryFile("clip.mp3")
        let media = RichMedia(title: "clip.mp3", url: tunnel, kind: .audio)
        let fetchers = RichMediaLoader.Fetchers(
            hermes: { _ in XCTFail("no Hermes path to ask for"); return local },
            mirror: { _, _ in local }
        )
        let loaded = try await RichMediaLoader.load(media, with: fetchers)
        XCTAssertEqual(loaded.source, .mirror)
    }

    func testTwoCardsOfTheSameMediaShareOneDownload() async throws {
        let local = temporaryFile("clip.mp4")
        var downloads = 0
        let fetchers = RichMediaLoader.Fetchers(
            hermes: { _ in
                downloads += 1
                try await Task.sleep(for: .milliseconds(50))
                return local
            },
            mirror: { _, _ in local }
        )
        let media = hermesMedia()
        async let first = RichMediaLoader.load(media, with: fetchers)
        async let second = RichMediaLoader.load(media, with: fetchers)
        _ = try await (first, second)
        _ = try await RichMediaLoader.load(media, with: fetchers)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(RichMediaLoader.cached(media)?.file, local)
    }

    func testADeletedCacheEntryIsFetchedAgain() async throws {
        let local = temporaryFile("clip.mp4")
        var downloads = 0
        let fetchers = RichMediaLoader.Fetchers(
            hermes: { _ in downloads += 1; return local },
            mirror: { _, _ in local }
        )
        _ = try await RichMediaLoader.load(hermesMedia(), with: fetchers)
        try FileManager.default.removeItem(at: local)
        XCTAssertNil(RichMediaLoader.cached(hermesMedia()))
        FileManager.default.createFile(atPath: local.path, contents: Data([0x01]))
        _ = try await RichMediaLoader.load(hermesMedia(), with: fetchers)
        XCTAssertEqual(downloads, 2)
    }
}
