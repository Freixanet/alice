import XCTest
@testable import Alice

/// A bot's download becomes a player card in the chat, not a link button.
///
/// cobalt's tunnel links carry no file extension (`/tunnel?id=…`), so the
/// filename the bot shows is the only thing that says "this is a video".
final class RichMediaTests: XCTestCase {
    private let tunnel = "http://MacBook-Pro-de-Marcos.local:9000/tunnel?id=6skTcd&exp=1&sig=HFpW"

    func testAnImageLineFromADownloadBecomesMedia() {
        let blocks = RichMarkdown.blocks("![Pole - una moto.mp4](\(tunnel))")
        XCTAssertEqual(blocks, [.media(RichMedia(
            title: "Pole - una moto.mp4",
            url: URL(string: tunnel)!,
            kind: .video
        ))])
    }

    func testALabeledDownloadWithAFilenameIsPromoted() {
        let blocks = RichMarkdown.blocks("[Pole - una moto.mp4](\(tunnel))")
        guard case let .media(media) = blocks.first else {
            return XCTFail("expected a media block, got \(blocks)")
        }
        XCTAssertEqual(media.kind, .video)
        XCTAssertEqual(media.title, "Pole - una moto.mp4")
    }

    func testAGenericLabelStaysALinkButton() {
        let blocks = RichMarkdown.blocks("[Descargar vídeo](\(tunnel))")
        XCTAssertEqual(blocks, [.links([RichLink(title: "Descargar vídeo", url: URL(string: tunnel)!)])])
    }

    func testABareMediaURLBecomesMedia() {
        let blocks = RichMarkdown.blocks("https://example.com/clip.mp3")
        guard case let .media(media) = blocks.first else {
            return XCTFail("expected a media block, got \(blocks)")
        }
        XCTAssertEqual(media.kind, .audio)
    }

    func testAudioAndImageExtensionsRouteToTheirPlayers() {
        let audio = RichMarkdown.blocks("![Cancion.mp3](\(tunnel))")
        let image = RichMarkdown.blocks("![](https://example.com/cover.png)")
        XCTAssertEqual(audio.first, .media(RichMedia(
            title: "Cancion.mp3", url: URL(string: tunnel)!, kind: .audio
        )))
        XCTAssertEqual(image.first, .media(RichMedia(
            title: "example.com", url: URL(string: "https://example.com/cover.png")!, kind: .image
        )))
    }

    func testMediaMidSentenceStaysALink() {
        let blocks = RichMarkdown.blocks("Mira esto ![clip](\(tunnel)) y dime.")
        XCTAssertFalse(blocks.contains { if case .media = $0 { return true }; return false },
                       "an inline image is a gesture, not a player: \(blocks)")
    }

    func testAReplyThatNamesTheFileThenPlaysItParsesWhole() {
        let reply = """
        ✓ **Pole - una moto.mp4**

        ![Pole - una moto.mp4](\(tunnel))

        También está en Alice → Files → Workspace → descargas.
        """
        let blocks = RichMarkdown.blocks(reply)
        let media = blocks.compactMap { block -> RichMedia? in
            if case let .media(value) = block { return value }
            return nil
        }
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media.first?.kind, .video)
        XCTAssertTrue(blocks.contains { block in
            if case let .paragraph(text) = block { return text.contains("Workspace") }
            return false
        })
    }

    func testAFileWithNoMediaExtensionStaysALink() {
        let blocks = RichMarkdown.blocks("![notas.txt](\(tunnel))")
        XCTAssertFalse(blocks.contains { if case .media = $0 { return true }; return false },
                       "a text file is not playable: \(blocks)")
    }
}