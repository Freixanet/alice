import XCTest
@testable import Alice

final class VoiceBargeInTests: XCTestCase {
    func testHerOwnVoiceIsNotTakenForThePersonTalkingOverHer() {
        let said = Set(VoiceConversation.words("Hoy tienes peluquería a las once y media, cariño."))
        let echo = VoiceConversation.words("hoy tienes peluquería a las once").filter { !said.contains($0) }
        XCTAssertLessThan(echo.count, VoiceConversation.bargeInWords)
        let person = VoiceConversation.words("espera, cámbiala para mañana por la tarde").filter { !said.contains($0) }
        XCTAssertGreaterThanOrEqual(person.count, VoiceConversation.bargeInWords)
        XCTAssertEqual(VoiceConversation.words("¡Peluquería!"), ["peluqueria"])
    }
}
