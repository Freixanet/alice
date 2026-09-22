import XCTest
@testable import Alice

/// What the voice says of a reply written for the eyes.
final class VoiceModeTests: XCTestCase {
    func testLinksReadAsTheirWordsAndMarksVanish() {
        let text = VoiceConversation.speakable("**Yo iría a [La Cuina](https://thefork.es/x)** [7]\n\n- Menú a 18 €")
        XCTAssertEqual(text, "Yo iría a La Cuina\nMenú a 18 €")
    }

    func testCardsCodeAndTablesAreNotRead() {
        let text = VoiceConversation.speakable("Tres sitios:\n```alice-ui\n{\"type\":\"places\"}\n```\n| A | B |\n| --- | --- |\nListo.")
        XCTAssertEqual(text, "Tres sitios:\nListo.")
    }

    func testAnOpenBlockIsNotReadHalfWritten() {
        XCTAssertEqual(VoiceConversation.speakable("Mira:\n```swift\nlet a ="), "Mira:")
    }
}
