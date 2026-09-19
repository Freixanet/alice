import XCTest
@testable import Alice

/// The drawer names a chat by its subject, not by its first keystrokes.
final class ConversationTitleTests: XCTestCase {
    func testTheSubjectSurvivesTheLeadIn() {
        XCTAssertEqual(
            ConversationTitle.from("hola, una cosa: quería que me ayudaras con la declaración de la renta"),
            "La declaración de la renta"
        )
        XCTAssertEqual(ConversationTitle.from("Can you compare Notion and Obsidian for me?"), "Compare Notion and Obsidian for me")
    }

    func testAGreetingAloneNamesNothing() {
        XCTAssertNil(ConversationTitle.from("hola"))
        XCTAssertNil(ConversationTitle.from("Hola!! "))
        XCTAssertNil(ConversationTitle.from("hi, hello"))
        XCTAssertNil(ConversationTitle.from("???"))
        XCTAssertNil(ConversationTitle.from(""))
    }

    func testAnAttachmentNamesAChatWithNoWords() {
        XCTAssertEqual(ConversationTitle.from("", attachmentName: "informe-q3.pdf"), "informe-q3.pdf")
        XCTAssertNil(ConversationTitle.from("", attachmentName: nil))
    }

    func testAMentionAndALinkAreNamedNotPasted() {
        XCTAssertEqual(
            ConversationTitle.from("@descargas https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "Descargas youtube.com"
        )
    }

    func testTheCutLandsOnAWord() {
        let title = ConversationTitle.from(
            "Explícame paso a paso cómo configurar un servidor de correo con Postfix y Dovecot en Debian"
        )!
        XCTAssertLessThanOrEqual(title.count, ConversationTitle.maxLength)
        XCTAssertTrue(title.hasSuffix("…"), title)
        XCTAssertFalse(title.dropLast().hasSuffix(" "), title)
        XCTAssertEqual(title, "Paso a paso cómo configurar un servidor…")
    }

    func testTheFirstRealLineWinsOverAGreetingLine() {
        XCTAssertEqual(ConversationTitle.from("Buenas\n\nQuiero un plan de comidas para la semana"), "Un plan de comidas para la semana")
    }

    func testMarkdownAndListMarkersAreDropped() {
        XCTAssertEqual(ConversationTitle.from("- **Revisar** el `contrato` de alquiler"), "Revisar el contrato de alquiler")
    }

    func testOnlyThePlaceholderIsReplaced() {
        XCTAssertTrue(ConversationTitle.isPlaceholder("New chat"))
        XCTAssertTrue(ConversationTitle.isPlaceholder("  "))
        XCTAssertFalse(ConversationTitle.isPlaceholder("Renta 2026"))
    }
}
