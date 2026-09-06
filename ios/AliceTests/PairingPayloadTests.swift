import XCTest
@testable import Alice

/// The pairing link is the front door for whatever a camera has ever
/// pointed at. These are the cases where parsing loosely would have handed
/// configuration — eventually the gateway key — to the wrong payload.
final class PairingPayloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func link(payloadJSON: String, version: String = "1") -> String {
        "alice://pair?v=\(version)&p=\(Self.base64URL(payloadJSON))"
    }

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func assertParse(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PairingPayload {
        try PairingPayload.parse(text, now: now)
    }

    func testParsesTheDocumentedShape() throws {
        let payload = try assertParse(link(payloadJSON: """
        {"c":"http://100.67.213.42:8643/claim","t":"tok","e":1700000300,"pr":"radar-ia"}
        """))

        XCTAssertEqual(payload.claimURL, URL(string: "http://100.67.213.42:8643/claim"))
        XCTAssertEqual(payload.token, "tok")
        XCTAssertEqual(payload.profileName, "radar-ia")
        XCTAssertEqual(payload.expiresAt, Date(timeIntervalSince1970: 1_700_000_300))
    }

    func testProfileNameIsOptionalAndBlankNormalizesAway() throws {
        let without = try assertParse(link(payloadJSON: """
        {"c":"https://hermes.test/claim","t":"tok","e":1700000300}
        """))
        XCTAssertNil(without.profileName)

        let blank = try assertParse(link(payloadJSON: """
        {"c":"https://hermes.test/claim","t":"tok","e":1700000300,"pr":"   "}
        """))
        XCTAssertNil(blank.profileName)
    }

    func testWhitespaceAroundAScannedLinkIsTolerated() throws {
        let payload = try assertParse("  " + link(payloadJSON: """
        {"c":"http://h:1/claim","t":"t","e":1700000300}
        """) + "\n")
        XCTAssertEqual(payload.token, "t")
    }

    func testRejectsExpiredCodesAtTheBoundary() {
        let expired = link(payloadJSON: """
        {"c":"http://h:1/claim","t":"t","e":1700000000}
        """)
        XCTAssertThrowsError(try assertParse(expired)) { error in
            XCTAssertEqual(error as? PairingPayload.ParseError, .expired)
        }
    }

    func testRejectsForeignLinksAndVersions() {
        XCTAssertThrowsError(try assertParse("https://example.test/pair?v=1&p=AA")) { error in
            XCTAssertEqual(error as? PairingPayload.ParseError, .notPairing)
        }
        XCTAssertThrowsError(try assertParse("alice://pair?v=2&p=AA")) { error in
            XCTAssertEqual(error as? PairingPayload.ParseError, .unsupportedVersion)
        }
    }

    func testRejectsDamagedPayloads() {
        let noPayload = "alice://pair?v=1"
        let badBase64 = "alice://pair?v=1&p=!!"
        let padded = "alice://pair?v=1&p=\(Self.base64URL("{}"))="
        let notJSON = link(payloadJSON: "hi")
        let emptyToken = link(payloadJSON: """
        {"c":"http://h:1/claim","t":"","e":1700000300}
        """)
        let foreignClaim = link(payloadJSON: """
        {"c":"ftp://h:1/claim","t":"t","e":1700000300}
        """)

        for damaged in [noPayload, badBase64, padded, notJSON, emptyToken, foreignClaim] {
            XCTAssertThrowsError(try assertParse(damaged), damaged) { error in
                XCTAssertEqual(error as? PairingPayload.ParseError, .malformed, damaged)
            }
        }
    }

    func testRejectsDuplicateExtraPathAndFragmentEnvelopeFields() {
        let valid = link(payloadJSON: #"{"c":"http://h:1/claim","t":"t","e":1700000300}"#)
        let duplicate = valid + "&v=1"
        let extra = valid + "&x=1"
        let path = valid.replacingOccurrences(of: "alice://pair?", with: "alice://pair/extra?")
        let fragment = valid + "#extra"

        for malformed in [duplicate, extra, path, fragment] {
            XCTAssertThrowsError(try assertParse(malformed), malformed) { error in
                XCTAssertEqual(error as? PairingPayload.ParseError, .malformed, malformed)
            }
        }
    }

    func testPaddingStandardAlphabetAndLeftoverBitsAreNotCanonical() {
        let standard = "alice://pair?v=1&p=\(Data("{}".utf8).base64EncodedString())"
        XCTAssertThrowsError(try assertParse(standard)) { error in
            XCTAssertEqual(error as? PairingPayload.ParseError, .malformed)
        }

        // "AB" decodes to the same byte as canonical "AA" in lenient base64
        // decoders. The parser must reject that alternate spelling.
        let leftover = "alice://pair?v=1&p=AB"
        XCTAssertThrowsError(try assertParse(leftover)) { error in
            XCTAssertEqual(error as? PairingPayload.ParseError, .malformed)
        }
    }

    func testExpiryMustBeAnIntegerOnTheWire() {
        let fractional = link(payloadJSON: """
        {"c":"http://h:1/claim","t":"t","e":1700000300.5}
        """)
        XCTAssertThrowsError(try assertParse(fractional)) { error in
            XCTAssertEqual(error as? PairingPayload.ParseError, .malformed)
        }
    }
}
