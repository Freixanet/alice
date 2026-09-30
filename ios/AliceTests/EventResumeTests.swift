import XCTest
@testable import Alice

/// A reply's events across a dropped socket (`EventResume`): duplicates dropped, gaps filled
/// from `session.events.since` in order, and nothing invented when Hermes cannot give them back.
final class EventResumeTests: XCTestCase {
    /// Hermes' replay ring for one session, as `session.events.since` answers from it.
    private actor FakeHermes: HermesRPCTransport {
        var ring: [Int: String] = [:]
        var truncated = false
        var epoch = "e1"
        private(set) var asked: [Int] = []

        func store(_ seq: Int, _ type: String) { ring[seq] = type }
        func setTruncated(_ value: Bool) { truncated = value }
        func setEpoch(_ value: String) { epoch = value }

        func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
            guard method == "session.events.since" else { return JSONObject([:]) }
            let seen = params["last_seen"] as? Int ?? 0
            asked.append(seen)
            let events: [[String: Any]] = ring.keys.sorted().filter { $0 > seen }.map {
                ["type": ring[$0] ?? "", "session_id": "live-1", "payload": [:], "seq": $0]
            }
            return JSONObject(["events": events, "truncated": truncated, "epoch": epoch,
                               "latest_seq": ring.keys.max() ?? 0])
        }

        nonisolated func events() -> AsyncStream<HermesRPCEvent> { AsyncStream { $0.finish() } }
    }

    private func frame(_ seq: Int?, _ type: String = "message.delta", session: String = "live-1") -> HermesRPCEvent {
        HermesRPCEvent(type: type, sessionID: session, payload: [:], seq: seq)
    }

    /// Feeds `frames` through a resume and returns the sequence numbers that came out.
    private func run(
        _ hermes: FakeHermes, _ frames: [HermesRPCEvent], follow: Bool = true,
        afterwards: ((EventResume) async -> Void)? = nil
    ) async -> [Int] {
        let resume = EventResume(rpc: hermes)
        if follow { await resume.follow("live-1") }
        let (input, feed) = AsyncStream<HermesRPCEvent>.makeStream()
        let output = resume.stream(input)
        for frame in frames { feed.yield(frame) }
        var seen: [Int] = []
        var iterator = output.makeAsyncIterator()
        if let afterwards {
            // Give the pump the live frames first, then let the caller ask for more.
            for _ in 0..<frames.count {
                if let event = await iterator.next() { seen.append(event.seq ?? -1) }
            }
            await afterwards(resume)
            feed.finish()
            while let event = await iterator.next() { seen.append(event.seq ?? -1) }
            return seen
        }
        feed.finish()
        while let event = await iterator.next() {
            seen.append(event.seq ?? -1)
        }
        return seen
    }

    func testDuplicatesAreDropped() async {
        let seen = await run(FakeHermes(), [frame(1), frame(2), frame(2), frame(1), frame(3)])
        XCTAssertEqual(seen, [1, 2, 3])
    }

    func testAGapIsFilledInOrderBeforeTheLiveEvent() async {
        let hermes = FakeHermes()
        for seq in 1...6 { await hermes.store(seq, "message.delta") }
        let seen = await run(hermes, [frame(1), frame(2), frame(6)])
        XCTAssertEqual(seen, [1, 2, 3, 4, 5, 6])
        let asked = await hermes.asked
        XCTAssertEqual(asked, [2])
    }

    func testCatchUpDeliversWhatEndedWhileTheSocketWasDown() async {
        let hermes = FakeHermes()
        for seq in 1...4 { await hermes.store(seq, seq == 4 ? "message.complete" : "message.delta") }
        let seen = await run(hermes, [frame(1), frame(2)]) { resume in
            let delivered = await resume.catchUp("live-1")
            XCTAssertEqual(delivered, 2)
        }
        XCTAssertEqual(seen, [1, 2, 3, 4])
    }

    func testATruncatedStretchIsNotStitched() async {
        let hermes = FakeHermes()
        for seq in 1...9 { await hermes.store(seq, "message.delta") }
        await hermes.setTruncated(true)
        let seen = await run(hermes, [frame(1), frame(9)])
        XCTAssertEqual(seen, [1, 9])
    }

    func testEachRuntimeHasItsOwnNumbers() async {
        // A resumed runtime after a restart has a new id and numbers from 1 on its own.
        let seen = await run(FakeHermes(), [frame(40), frame(41), frame(1, session: "live-2"), frame(2, session: "live-2")])
        XCTAssertEqual(seen, [40, 41, 1, 2])
    }

    func testAnAnnouncedEpochResetsTheNumbering() async {
        let ready = { (epoch: String) in
            HermesRPCEvent(type: "gateway.ready", sessionID: "", payload: ["replay_epoch": epoch])
        }
        let seen = await run(FakeHermes(), [ready("e1"), frame(5), ready("e2"), frame(3), frame(4)])
        XCTAssertEqual(seen, [-1, 5, -1, 3, 4])
    }

    func testAnotherHermesAnswersNothingToReplay() async {
        let hermes = FakeHermes()
        for seq in 1...5 { await hermes.store(seq, "message.delta") }
        await hermes.setEpoch("other")
        let ready = HermesRPCEvent(type: "gateway.ready", sessionID: "", payload: ["replay_epoch": "e1"])
        let seen = await run(hermes, [ready, frame(1), frame(5)])
        XCTAssertEqual(seen, [-1, 1, 5])
    }

    func testUnfollowedSessionsAreNotFilled() async {
        let hermes = FakeHermes()
        for seq in 1...5 { await hermes.store(seq, "message.delta") }
        let seen = await run(hermes, [frame(1), frame(5)], follow: false)
        XCTAssertEqual(seen, [1, 5])
        let asked = await hermes.asked
        XCTAssertTrue(asked.isEmpty)
    }

    func testEventsWithoutANumberPassThrough() async {
        let seen = await run(FakeHermes(), [frame(nil, "approval.request"), frame(1), frame(nil, "clarify.request")])
        XCTAssertEqual(seen, [-1, 1, -1])
    }

    func testParsingKeepsTheNumber() {
        let event = HermesRPCEvent.parse(["type": "message.delta", "session_id": "s", "payload": ["text": "hola"], "seq": 7])
        XCTAssertEqual(event?.seq, 7)
        XCTAssertEqual(event?.payload["text"] as? String, "hola")
        guard case let .event(live) = HermesRPCClient.inbound([
            "jsonrpc": "2.0", "method": "event",
            "params": ["type": "message.delta", "session_id": "s", "payload": [:], "seq": 12],
        ]) else { return XCTFail("not an event") }
        XCTAssertEqual(live.seq, 12)
    }
}
