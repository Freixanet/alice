import XCTest
@testable import Alice

/// A bot's download becomes a player card in the chat, not a link button.
///
/// cobalt's tunnel links carry no file extension (`/tunnel?id=…`), so the
/// filename the bot shows is the only thing that says "this is a video". A
/// file saved on the Hermes machine is written as `alice://file?path=…&url=…`
/// and keeps both where it is and the tunnel it came from.
final class RichMediaTests: XCTestCase {
    private let tunnel = "http://MacBook-Pro-de-Marcos.local:9000/tunnel?id=6skTcd&exp=1&sig=HFpW"
    private let saved = "/Users/mfreixanet/.hermes/profiles/descargas/workspace/descargas/Pole (1080p, h264).mp4"

    private func encoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    private var hermesLine: String {
        "![Pole (1080p, h264).mp4](alice://file?path=\(encoded(saved))&url=\(encoded(tunnel)))"
    }

    private func media(in blocks: [RichBlock]) -> [RichMedia] {
        blocks.compactMap { block -> RichMedia? in
            if case let .media(value) = block { return value }
            return nil
        }
    }

    // ── web addresses ────────────────────────────────────────────────────────

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
        XCTAssertNil(media.hermesPath)
        XCTAssertEqual(media.webURL, URL(string: tunnel))
    }

    func testAGenericLabelStaysALinkButton() {
        let blocks = RichMarkdown.blocks("[Descargar vídeo](\(tunnel))")
        XCTAssertEqual(blocks, [.links([RichLink(title: "Descargar vídeo", url: URL(string: tunnel)!)])])
    }

    func testABareMediaURLBecomesMedia() {
        let blocks = RichMarkdown.blocks("https://example.com/clip.mp3")
        XCTAssertEqual(media(in: blocks).first?.kind, .audio)
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
        XCTAssertTrue(media(in: blocks).isEmpty, "an inline image is a gesture, not a player: \(blocks)")
    }

    func testAFileWithNoMediaExtensionStaysALink() {
        let blocks = RichMarkdown.blocks("![notas.txt](\(tunnel))")
        XCTAssertTrue(media(in: blocks).isEmpty, "a text file on the web is not playable: \(blocks)")
    }

    // ── files on the Hermes machine ──────────────────────────────────────────

    func testAHermesFileLineKeepsItsPathAndItsMirror() {
        let found = media(in: RichMarkdown.blocks(hermesLine))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .video)
        XCTAssertEqual(found.first?.title, "Pole (1080p, h264).mp4")
        XCTAssertEqual(found.first?.hermesPath, saved)
        XCTAssertEqual(found.first?.webURL, URL(string: tunnel))
        XCTAssertEqual(found.first?.cacheKey, "hermes:" + saved)
    }

    func testAHermesFileWithoutAMirrorHasNoWebAddress() {
        let line = "![song.mp3](alice://file?path=\(encoded("/w/descargas/song.mp3")))"
        let found = media(in: RichMarkdown.blocks(line))
        XCTAssertEqual(found.first?.kind, .audio)
        XCTAssertEqual(found.first?.hermesPath, "/w/descargas/song.mp3")
        XCTAssertNil(found.first?.webURL)
    }

    func testTheKindComesFromThePathWhenTheLabelHasNoExtension() {
        let line = "![Una moto](alice://file?path=\(encoded("/w/descargas/moto.MP4")))"
        let found = media(in: RichMarkdown.blocks(line))
        XCTAssertEqual(found.first?.kind, .video)
        XCTAssertEqual(found.first?.title, "Una moto")
        XCTAssertEqual(found.first?.fileName, "Una moto.mp4", "the saved copy needs the extension the label lacks")
    }

    func testAnEmptyLabelFallsBackToTheFileName() {
        let line = "![](alice://file?path=\(encoded("/w/descargas/clip.mov")))"
        XCTAssertEqual(media(in: RichMarkdown.blocks(line)).first?.title, "clip.mov")
    }

    func testAHermesFileOfAnyKindIsACardBecauseThereIsNoBrowserForIt() {
        let line = "![informe.pdf](alice://file?path=\(encoded("/w/informe.pdf")))"
        let found = media(in: RichMarkdown.blocks(line))
        XCTAssertEqual(found.first?.kind, .file)
        XCTAssertEqual(found.first?.hermesPath, "/w/informe.pdf")
    }

    func testAnUnencodedPathWithSpacesStillParses() {
        // A model that "tidied" the percent escapes must not lose the player.
        let line = "![Pole - una moto.mp4](alice://file?path=/w/descargas/Pole - una moto.mp4)"
        let found = media(in: RichMarkdown.blocks(line))
        XCTAssertEqual(found.first?.kind, .video)
        XCTAssertEqual(found.first?.hermesPath, "/w/descargas/Pole - una moto.mp4")
    }

    func testAnAliceFileLinkWithoutAPathIsNotMedia() {
        XCTAssertTrue(media(in: RichMarkdown.blocks("![x.mp4](alice://file)")).isEmpty)
        XCTAssertTrue(media(in: RichMarkdown.blocks("![x.mp4](alice://file?url=\(encoded(tunnel))))")).isEmpty)
    }

    func testReplyButtonsAreNeverMistakenForMedia() {
        let blocks = RichMarkdown.blocks("[Sí, bájalo](alice://reply?text=S%C3%AD)")
        XCTAssertEqual(blocks, [.buttons([RichReplyButton(title: "Sí, bájalo", reply: "Sí")])])
    }

    func testAReplyThatNamesTheFileThenPlaysItParsesWhole() {
        let reply = """
        ✓ **Pole (1080p, h264).mp4**

        \(hermesLine)

        También está en Alice → Files → Workspace → descargas.
        """
        let blocks = RichMarkdown.blocks(reply)
        let found = media(in: blocks)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .video)
        XCTAssertEqual(found.first?.hermesPath, saved)
        XCTAssertTrue(blocks.contains { block in
            if case let .paragraph(text) = block { return text.contains("Workspace") }
            return false
        })
    }

    func testSeveralPiecesEachGetTheirOwnCard() {
        let reply = """
        ✓ **Carrusel guardado**

        ![foto 1.jpg](alice://file?path=\(encoded("/w/d/foto 1.jpg"))&url=\(encoded("https://cdn/1")))

        ![foto 2.jpg](alice://file?path=\(encoded("/w/d/foto 2.jpg"))&url=\(encoded("https://cdn/2")))

        ![clip 3.mp4](alice://file?path=\(encoded("/w/d/clip 3.mp4")))
        """
        let found = media(in: RichMarkdown.blocks(reply))
        XCTAssertEqual(found.map(\.kind), [.image, .image, .video])
        XCTAssertEqual(found.map(\.hermesPath), ["/w/d/foto 1.jpg", "/w/d/foto 2.jpg", "/w/d/clip 3.mp4"])
    }

    func testTheSavedNameCarriesTheMediaExtension() {
        let web = RichMedia(title: "cover", url: URL(string: "https://x/cover.PNG")!, kind: .image)
        XCTAssertEqual(web.fileName, "cover.png")
        let labeled = RichMedia(title: "clip.mp4", url: URL(string: tunnel)!, kind: .video)
        XCTAssertEqual(labeled.fileName, "clip.mp4")
        let blank = RichMedia(title: "   ", url: URL(string: tunnel)!, kind: .video)
        XCTAssertEqual(blank.fileName, "media")
    }
}
