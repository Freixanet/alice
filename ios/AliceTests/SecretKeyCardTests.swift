import XCTest
@testable import Alice

final class SecretKeyCardTests: XCTestCase {
    func testKeyLinksBecomeTheSecureCardAndHermesOwnNamesAreRefused() {
        XCTAssertEqual(SecretKeyCard.keyName(for: "search"), "EXA_API_KEY")
        XCTAssertEqual(SecretKeyCard.keyName(for: "secret/GITHUB_TOKEN"), "GITHUB_TOKEN")
        XCTAssertNil(SecretKeyCard.keyName(for: "secret/HERMES_HOME"))
        XCTAssertNil(SecretKeyCard.keyName(for: "secret/API_SERVER_KEY"))
        XCTAssertNil(SecretKeyCard.keyName(for: "secret/lowercase"))
        XCTAssertNil(SecretKeyCard.keyName(for: "calendar"))
    }

    func testTheLinkLeavesTheTextAndBecomesAnOffer() {
        let (text, services) = RichMarkdown.connectOffers(
            in: "Necesito tu token de GitHub.\n[Dar clave](alice://connect/secret/GITHUB_TOKEN)")
        XCTAssertEqual(text, "Necesito tu token de GitHub.")
        XCTAssertEqual(services, ["secret/GITHUB_TOKEN"])
    }
}
