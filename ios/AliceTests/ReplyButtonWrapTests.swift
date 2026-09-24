import XCTest
@testable import Alice

final class ReplyButtonWrapTests: XCTestCase {
    func testAReplyLinkBrokenAcrossLinesStillBecomesAButton() {
        let text = """
        - Compra del pienso en Piensos Raposo.
        [Recuérdamelo mañana](alice://reply?text=Recu%C3%A9rdame%20ma%C3%B1ana%20a%20las%209%3A%20terminar%20la%20compra%20del
        %20pienso%20en%20Piensos%20Raposo)
        """
        let (rest, buttons) = RichMarkdown.replyButtons(in: text)
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons.first?.reply, "Recuérdame mañana a las 9: terminar la compra del pienso en Piensos Raposo")
        XCTAssertFalse(rest.contains("alice://"))
        XCTAssertFalse(rest.contains("%20"))
    }
}
