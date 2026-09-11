import XCTest
@testable import Alice

/// A message to a bot is followed until it is answered, stopped, or known to
/// be lost — and says which.
///
/// What happened on a phone: Radar IA spent ten minutes at a time waiting out a
/// rate-limited model. The phone locked and the socket died; the reply came
/// back drawn as a failure while the bot kept working. Stop sent the stored
/// session id, which Hermes refused. A message sent meanwhile was folded into
/// the dying task and vanished without a word.
final class BotChatDeliveryTests: XCTestCase {
    // MARK: - A fake agent

    private actor FakeRPC: HermesRPCTransport {
        struct Call: Equatable, Sendable {
            let method: String
            let sessionID: String?
            let omitMessages: Bool
        }

        private var results: [String: JSONObject]
        private var failures: [String: Int] = [:]
        private(set) var calls: [Call] = []

        init(_ results: [String: [String: Any]] = [:]) {
            self.results = results.mapValues(JSONObject.init)
        }

        func failing(_ method: String) { failures[method, default: 0] += 1 }

        func call(_ method: String, _ params: JSONObject) async throws -> JSONObject {
            calls.append(Call(
                method: method,
                sessionID: params["session_id"] as? String,
                omitMessages: (params["omit_messages"] as? Bool) == true
            ))
            if let left = failures[method], left > 0 {
                failures[method] = left - 1
                throw Dropped()
            }
            return results[method] ?? JSONObject([:])
        }

        nonisolated func events() -> AsyncStream<HermesRPCEvent> {
            AsyncStream { $0.finish() }
        }
    }

    private struct Dropped: Error {}

    private static let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    private static func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private static func frame(
        _ type: String, session: String = "live-1", _ payload: [String: Any] = [:]
    ) -> HermesRPCEvent {
        HermesRPCEvent(type: type, sessionID: session, payload: payload)
    }

    private static func turn(
        _ id: String, _ role: Message.Role, _ text: String, _ seconds: TimeInterval
    ) -> BotChatTurn {
        BotChatTurn(id: id, role: role, content: text, createdAt: at(seconds))
    }

    private static func watch(_ disposition: BotChatSubmission.Disposition = .started) -> BotTurnWatch {
        BotTurnWatch(
            submission: BotChatSubmission(liveSessionID: "live-1", disposition: disposition),
            now: t0
        )
    }

    // MARK: - What Hermes did with the message

    func testASendToABusyBotSaysWhatHermesDidWithIt() async throws {
        let cases: [(status: String?, expected: BotChatSubmission.Disposition)] = [
            (nil, .started), ("streaming", .started), ("queued", .queued),
            ("steered", .foldedIn), ("redirected", .foldedIn),
        ]
        for (status, expected) in cases {
            var submitted: [String: Any] = [:]
            if let status { submitted["status"] = status }
            let rpc = FakeRPC([
                "session.resume": ["session_id": "live-1", "messages": [Any]()],
                "prompt.submit": submitted,
            ])
            let submission = try await WebSocketBotChatSource(rpc: rpc)
                .submit(profile: "radar-ia", sessionID: "stored", text: "hola")
            XCTAssertEqual(submission.disposition, expected, "status \(status ?? "none")")
            XCTAssertEqual(submission.liveSessionID, "live-1")
        }
    }

    func testABusyBotsReplyIsLabelledWithWhatItIsWaitingOn() {
        XCTAssertNil(AppStore.deliveryNote(for: .started, label: "Radar IA"))
        let queued = AppStore.deliveryNote(for: .queued, label: "Radar IA")
        let foldedIn = AppStore.deliveryNote(for: .foldedIn, label: "Radar IA")
        XCTAssertTrue(queued?.contains("Radar IA") == true)
        XCTAssertTrue(foldedIn?.contains("Radar IA") == true)
        XCTAssertNotEqual(queued, foldedIn)
    }

    // MARK: - Stop

    func testStopAddressesTheLiveRuntimeNotTheStoredRow() async throws {
        let rpc = FakeRPC()
        let stopped = try await WebSocketBotChatSource(rpc: rpc).interrupt(
            profile: "radar-ia",
            storedSessionID: "20260905_104136_281747",
            liveSessionID: "live-1"
        )
        XCTAssertTrue(stopped)
        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["session.interrupt"])
        XCTAssertEqual(calls.first?.sessionID, "live-1",
                       "Hermes answers 'session not found' to the stored id")
    }

    func testStopFindsTheRunningTurnWhenItsRuntimeIsGone() async throws {
        let rpc = FakeRPC([
            "session.resume": ["session_id": "live-2", "running": true, "messages": [Any]()],
        ])
        await rpc.failing("session.interrupt")
        let stopped = try await WebSocketBotChatSource(rpc: rpc).interrupt(
            profile: "radar-ia", storedSessionID: "stored", liveSessionID: "live-1"
        )
        XCTAssertTrue(stopped)
        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method),
                       ["session.interrupt", "session.resume", "session.interrupt"])
        XCTAssertEqual(calls.map(\.sessionID), ["live-1", "stored", "live-2"])
    }

    func testStopWithNothingRunningInterruptsNothing() async throws {
        let rpc = FakeRPC([
            "session.resume": ["session_id": "live-2", "running": false, "messages": [Any]()],
        ])
        let stopped = try await WebSocketBotChatSource(rpc: rpc).interrupt(
            profile: "radar-ia", storedSessionID: "stored", liveSessionID: nil
        )
        XCTAssertFalse(stopped)
        let methods = await rpc.calls.map(\.method)
        XCTAssertEqual(methods, ["session.resume"])
    }

    // MARK: - Asking about a quiet turn

    func testAQuietTurnIsAskedAboutWithoutItsTranscript() async throws {
        let rpc = FakeRPC(["session.activate": ["session_id": "live-1", "running": true]])
        let state = try await WebSocketBotChatSource(rpc: rpc).turnState(
            profile: "radar-ia", storedSessionID: "stored", liveSessionID: "live-1"
        )
        XCTAssertEqual(state, BotTurnState(liveSessionID: "live-1", running: true))
        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["session.activate"])
        XCTAssertEqual(calls.first?.omitMessages, true)
    }

    func testAReapedRuntimeIsFoundAgainByResumingTheStoredChat() async throws {
        let rpc = FakeRPC([
            "session.activate": ["session_id": "live-1", "running": true],
            "session.resume": ["session_id": "live-9", "running": false, "messages": [Any]()],
        ])
        await rpc.failing("session.activate")
        let state = try await WebSocketBotChatSource(rpc: rpc).turnState(
            profile: "radar-ia", storedSessionID: "stored", liveSessionID: "live-1"
        )
        XCTAssertEqual(state, BotTurnState(liveSessionID: "live-9", running: false))
        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["session.activate", "session.resume"])
        XCTAssertEqual(calls.last?.sessionID, "stored")
    }

    // MARK: - Which frames are this reply's

    func testOnlyThisChatsFramesReachTheReply() {
        var watch = Self.watch()
        let elsewhere = watch.receive(
            Self.frame("message.delta", session: "someone-else", ["text": "x"]), now: Self.t0
        )
        XCTAssertEqual(elsewhere, .ignore)
        let delta = watch.receive(Self.frame("message.delta", ["text": "hola"]), now: Self.t0)
        XCTAssertEqual(delta, .apply)
        // A subagent's completion carries no status and does not end the parent.
        let child = watch.receive(Self.frame("message.complete", ["text": "child"]), now: Self.t0)
        XCTAssertEqual(child, .apply)
        let done = watch.receive(Self.frame("message.complete", ["status": "complete"]), now: Self.t0)
        XCTAssertEqual(done, .finish)
    }

    func testAQueuedMessageWaitsOutTheTaskAheadOfIt() {
        var watch = Self.watch(.queued)
        // The bot's other task is still talking; none of it is this reply.
        let theirs = watch.receive(Self.frame("message.delta", ["text": "otro"]), now: Self.t0)
        XCTAssertEqual(theirs, .ignore)
        let theirEnd = watch.receive(Self.frame("message.complete", ["status": "complete"]), now: Self.t0)
        XCTAssertEqual(theirEnd, .ownTurnBegan)
        let ours = watch.receive(Self.frame("message.delta", ["text": "hola"]), now: Self.t0)
        XCTAssertEqual(ours, .apply)
        let ourEnd = watch.receive(Self.frame("message.complete", ["status": "complete"]), now: Self.t0)
        XCTAssertEqual(ourEnd, .finish)
    }

    // MARK: - Silence

    func testSilenceIsAskedAboutOnlyOnceItHasLasted() {
        var watch = Self.watch()
        XCTAssertFalse(watch.shouldCheck(now: Self.at(10)))
        XCTAssertTrue(watch.shouldCheck(now: Self.at(BotTurnWatch.quietInterval)))
        _ = watch.receive(Self.frame("tool.start", ["name": "search"]), now: Self.at(25))
        XCTAssertFalse(watch.shouldCheck(now: Self.at(40)), "a frame is news")
    }

    func testABotStillWorkingIsWaitedForUnderItsNewRuntimeID() {
        var watch = Self.watch()
        let step = watch.checked(
            .success(BotTurnState(liveSessionID: "live-2", running: true)), now: Self.at(60)
        )
        XCTAssertEqual(step, .keepWaiting(liveSessionIDChanged: true))
        XCTAssertEqual(watch.liveSessionID, "live-2")
        let stale = watch.receive(Self.frame("message.delta", ["text": "x"]), now: Self.at(61))
        XCTAssertEqual(stale, .ignore, "frames now arrive under the new runtime id")
        XCTAssertFalse(watch.shouldCheck(now: Self.at(70)))
    }

    func testATurnThatEndedUnseenIsSettledFromTheTranscript() {
        var watch = Self.watch()
        let step = watch.checked(
            .success(BotTurnState(liveSessionID: "live-1", running: false)), now: Self.at(60)
        )
        XCTAssertEqual(step, .endedUnseen)
    }

    func testRepeatedlyFailingToReachHermesEndsTheWait() {
        var watch = Self.watch()
        for _ in 1..<BotTurnWatch.attemptsBeforeLosingTouch {
            let step = watch.checked(.failure(Dropped()), now: Self.at(60))
            XCTAssertEqual(step, .reconnecting)
        }
        let last = watch.checked(.failure(Dropped()), now: Self.at(60))
        XCTAssertEqual(last, .lostTouch)
    }

    func testReachingHermesAgainStartsTheCountOver() {
        var watch = Self.watch()
        for _ in 1..<BotTurnWatch.attemptsBeforeLosingTouch {
            _ = watch.checked(.failure(Dropped()), now: Self.at(60))
        }
        _ = watch.checked(.success(BotTurnState(liveSessionID: "live-1", running: true)), now: Self.at(60))
        let step = watch.checked(.failure(Dropped()), now: Self.at(90))
        XCTAssertEqual(step, .reconnecting)
    }

    func testACheckThatNeverHearsBackGivesUp() async {
        do {
            _ = try await BotTurnWatch.answer(within: .milliseconds(50)) { () async throws -> Bool in
                try await Task.sleep(for: .seconds(5))
                return true
            }
            XCTFail("a call on a dead socket must not hold the watch")
        } catch {
            XCTAssertTrue(error is BotTurnWatch.NoAnswer)
        }
    }

    func testACheckThatAnswersInTimeIsUsed() async throws {
        let value = try await BotTurnWatch.answer(within: .seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    // MARK: - A persisted copy replaces the local one

    func testASentMessageIsShownOnceItIsPersisted() {
        let sent = Message(id: "local", role: .user, content: "¿algo nuevo?", createdAt: Self.at(100))
        let merged = BotChatSync.merge(
            [Self.turn("r-1", .user, "¿algo nuevo? ", 103)], into: [sent]
        )
        XCTAssertEqual(merged.map(\.id), ["r-1"])
    }

    func testAFinishedReplyIsShownOnceItIsPersisted() {
        let reply = Message(
            id: "local-reply", role: .assistant, content: "Sin novedades.",
            createdAt: Self.at(100), runStatus: .completed
        )
        let merged = BotChatSync.merge(
            [Self.turn("r-2", .assistant, "Sin novedades.", 160)],
            into: [reply], botName: "radar-ia"
        )
        XCTAssertEqual(merged.map(\.id), ["r-2"])
    }

    func testTheSameMessageSentTwiceStaysTwice() {
        let first = Message(id: "a", role: .user, content: "ok", createdAt: Self.at(100))
        let second = Message(id: "b", role: .user, content: "ok", createdAt: Self.at(200))
        // Only the first has been persisted so far.
        let merged = BotChatSync.merge([Self.turn("r-1", .user, "ok", 101)], into: [first, second])
        XCTAssertEqual(merged.map(\.id), ["r-1", "b"])
    }

    func testAnEarlierIdenticalMessageIsNotThisOnesCopy() {
        let again = Message(id: "b", role: .user, content: "ok", createdAt: Self.at(1_000))
        let merged = BotChatSync.merge([Self.turn("r-old", .user, "ok", 100)], into: [again])
        XCTAssertEqual(merged.map(\.id), ["r-old", "b"])
    }

    // MARK: - A reply nobody was watching

    func testAReplyThatLandedWhileNobodyWatchedReplacesItsPlaceholder() {
        let placeholder = Message(id: "p", role: .assistant, content: "", createdAt: Self.at(100), pending: true)
        let landed = Message(id: "r", role: .assistant, content: "informe", createdAt: Self.at(900), remoteID: "r")
        let settled = BotChatSync.settle([placeholder, landed], watching: [], note: "Lost touch")
        XCTAssertEqual(settled.map(\.id), ["r"])
    }

    func testAReplyNotYetLandedSaysTheBotMayStillBeWorking() {
        let placeholder = Message(id: "p", role: .assistant, content: "", createdAt: Self.at(100), pending: true)
        let settled = BotChatSync.settle([placeholder], watching: [], note: "Lost touch")
        XCTAssertEqual(settled.count, 1)
        XCTAssertFalse(settled[0].pending, "no spinner that never ends")
        XCTAssertTrue(settled[0].awaitingRemote)
        XCTAssertEqual(settled[0].deliveryNote, "Lost touch")
        XCTAssertNil(settled[0].error, "not drawn as a failure")
    }

    func testTheReplyBeingWatchedIsLeftAlone() {
        let placeholder = Message(id: "p", role: .assistant, content: "", createdAt: Self.at(100), pending: true)
        let settled = BotChatSync.settle([placeholder], watching: ["p"], note: "Lost touch")
        XCTAssertTrue(settled[0].pending)
        XCTAssertFalse(settled[0].awaitingRemote)
    }

    func testAnEarlierReplyIsNotThisOnesAnswer() {
        let earlier = Message(id: "r", role: .assistant, content: "ayer", createdAt: Self.at(50), remoteID: "r")
        let placeholder = Message(id: "p", role: .assistant, content: "", createdAt: Self.at(100), pending: true)
        let settled = BotChatSync.settle([earlier, placeholder], watching: [], note: "Lost touch")
        XCTAssertEqual(settled.map(\.id), ["r", "p"])
    }

    // MARK: - Archives

    func testRepliesSavedByAnOlderBuildStillOpen() throws {
        let json = #"{"id":"m","role":"assistant","content":"hola","createdAt":0,"pending":true}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        XCTAssertNil(message.deliveryNote)
        XCTAssertFalse(message.awaitingRemote)

        var waiting = message
        waiting.awaitingRemote = true
        waiting.deliveryNote = "Lost touch"
        let restored = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(waiting))
        XCTAssertTrue(restored.awaitingRemote)
        XCTAssertEqual(restored.deliveryNote, "Lost touch")
    }
}
