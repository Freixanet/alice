import XCTest
@testable import Alice

/// A Hermes event Alice does not know is kept on record, never lost, and never
/// mistaken for something it is not.
final class HermesUnknownEventsTests: XCTestCase {
    private var ledger: HermesUnknownEvents!

    override func setUp() {
        super.setUp()
        ledger = HermesUnknownEvents()
        HermesUnknownEvents.shared.reset()
    }

    override func tearDown() {
        HermesUnknownEvents.shared.reset()
        super.tearDown()
    }

    func testAnUnknownKindIsCountedWithItsKeysNotItsContents() {
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.record("run.paused", transport: .runStream, payload: ["reason": "budget", "secret": "x"], now: then)
        ledger.record("run.paused", transport: .runStream, payload: ["reason": "quota"], now: then + 5)

        let all = ledger.all
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].type, "run.paused")
        XCTAssertEqual(all[0].count, 2)
        XCTAssertEqual(all[0].keys, ["reason"], "the latest shape is kept, and only key names")
        XCTAssertEqual(all[0].lastSeen, then + 5)
    }

    func testTheSameNameOnAnotherTransportIsAnotherSighting() {
        ledger.record("turn.paused", transport: .runStream, payload: [:])
        ledger.record("turn.paused", transport: .botSocket, payload: [:])
        XCTAssertEqual(ledger.all.count, 2)
    }

    func testTheLedgerIsBoundedAndForgetsTheOldest() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(HermesUnknownEvents.capacity + 3) {
            ledger.record("kind.\(index)", transport: .liveEvents, payload: [:], now: start + Double(index))
        }
        let all = ledger.all
        XCTAssertEqual(all.count, HermesUnknownEvents.capacity)
        XCTAssertFalse(all.contains { $0.type == "kind.0" })
        XCTAssertTrue(all.contains { $0.type == "kind.\(HermesUnknownEvents.capacity + 2)" })
    }

    func testABlankKindIsNotRecorded() {
        ledger.record("  ", transport: .botSocket, payload: [:])
        XCTAssertTrue(ledger.isEmpty)
    }

    /// The parsers still answer "nothing to draw" for a kind they do not know:
    /// recording is a side effect, never a change in what the reply shows.
    func testUnknownStreamKindsStillProduceNoChatEvent() {
        let frame = HermesRPCEvent(type: "run.paused", sessionID: "s1", payload: ["reason": "budget"])
        XCTAssertNil(AppStore.chatEvent(from: frame))
        XCTAssertNil(LiveEvents.event(
            from: frame,
            session: .init(profile: "radar-ia", sessionID: "s1", sessionKey: nil, conversationID: nil, label: "Radar")
        ))
        XCTAssertTrue(HermesUnknownEvents.shared.all.contains { $0.type == "run.paused" })
    }

    func testKnownBookkeepingIsNotReportedAsUnknown() {
        HermesUnknownEvents.shared.reset()
        for type in ["reasoning.delta", "notification.show", "session.info", "message.start"] {
            _ = AppStore.chatEvent(from: HermesRPCEvent(type: type, sessionID: "s1", payload: [:]))
        }
        XCTAssertTrue(HermesUnknownEvents.shared.isEmpty)
    }
}
