import XCTest
@testable import Alice

/// A notification from the Mac watcher opens Alice on the chat it is about.
final class NotificationLinkTests: XCTestCase {
    func testABotLinkNamesTheProfile() throws {
        let url = try XCTUnwrap(URL(string: "alice://open?bot=radar-ia"))
        XCTAssertEqual(NotificationLink(url: url), .bot("radar-ia"))
    }

    func testTheHomeLinkOpensAlicesOwnChat() throws {
        let url = try XCTUnwrap(URL(string: "alice://open?chat=home"))
        XCTAssertEqual(NotificationLink(url: url), .chat(nil))
    }

    func testAChatLinkNamesTheConversation() throws {
        let url = try XCTUnwrap(URL(string: "alice://open?chat=4F1C"))
        XCTAssertEqual(NotificationLink(url: url), .chat("4F1C"))
    }

    func testPairingAndStrangerLinksAreNotNotifications() throws {
        for text in ["alice://pair?code=1", "alice://open", "alice://open?bot=", "https://open?bot=x"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertNil(NotificationLink(url: url), text)
        }
    }
}
