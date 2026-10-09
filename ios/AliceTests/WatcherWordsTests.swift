import Foundation
import XCTest
@testable import Alice

final class WatcherWordsTests: XCTestCase {
    func testOldAndIncompleteEmailWatchesRequireSetup() throws {
        let old = Data(#"{"id":"abc","name":"Barkibu","source":"email","status":"paused","reason":"user","pending":2}"#.utf8)
        let watcher = try JSONDecoder().decode(WatcherSnapshot.Watcher.self, from: old)
        XCTAssertTrue(watcher.needsEmailFilter)
        XCTAssertEqual(WatcherWords.status(watcher.status, reason: watcher.reason, incomplete: true), String(localized: "Needs setup"))
        let configured = Data(#"{"id":"abc","name":"Barkibu","source":"email","status":"active","pending":0,"config":{"query":"from:barkibu.com","every_minutes":5}}"#.utf8)
        let ready = try JSONDecoder().decode(WatcherSnapshot.Watcher.self, from: configured)
        XCTAssertFalse(ready.needsEmailFilter)
        XCTAssertEqual(ready.config?.every_minutes, 5)
    }

    func testMissingEmailFilterHasAnActionableMessage() {
        let message = WatcherWords.failure(DashboardClient.Failure.http(400, "Provide an explicit Gmail search query in config.query"))
        XCTAssertEqual(message, WatcherWords.missingFilter)
        XCTAssertFalse(message.contains("config.query"))
        XCTAssertFalse(message.contains("400"))
    }

    func testPreviewDoesNotExposePayloadOrInventSuccessfulAlerts() {
        XCTAssertFalse(WatcherWords.preview([["error": "PRIVATE EMAIL PAYLOAD"]]).contains("PRIVATE"))
        let summary = WatcherWords.preview([["notified": true, "acked": true], ["notified": false, "acked": true], ["notified": false, "acked": false]])
        XCTAssertEqual(summary, String(localized: "Items checked: \(3). Alerts Alice would send: \(1). Items still undecided: \(1). Nothing was sent."))
    }
}
