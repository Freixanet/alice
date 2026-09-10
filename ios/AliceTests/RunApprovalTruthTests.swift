import XCTest
@testable import Alice

/// Approvals from the main chat showed no reason and, for older rows, a network
/// error under "Show exact command". Three faults: Hermes' statement of the
/// risk was read from the wrong field, the command's place was filled from the
/// wrong one, and nothing ever asked Hermes whether a request was still waiting
/// — it refuses them itself after a few minutes.
final class RunApprovalTruthTests: XCTestCase {

    private let chunk = """
    {"event":"approval.request","run_id":"run-9","request_id":"req-9","tool":"terminal",
     "description":"recursive delete","command":"rm -rf ./build","smart_denied":true,
     "choices":["once","deny"]}
    """

    private func approval() throws -> Message.Approval {
        let events = HermesRunProtocol.events(from: chunk, fallbackRunID: "x")
        guard events.count == 2, case let .approval(approval) = events[1] else {
            struct NoApproval: Error {}
            XCTFail("the run chunk did not parse as an approval")
            throw NoApproval()
        }
        return approval
    }

    func testARunApprovalKeepsItsReasonAndWarning() throws {
        let approval = try approval()
        XCTAssertEqual(approval.title, "terminal")
        XCTAssertEqual(approval.hermesDescription, "recursive delete")
        XCTAssertEqual(approval.smartDenied, true)

        let event = AppStore.approvalActivityEvent(
            approval, profile: nil, label: "Alice", conversationID: "c1", transport: .gatewayRun
        )
        XCTAssertEqual(event.title, "Alice needs your OK")
        XCTAssertEqual(event.summary, "Wants to delete files or folders, including everything inside them")
        XCTAssertEqual(event.detail, "rm -rf ./build")
        XCTAssertEqual(event.approvalDescription, "recursive delete")
        XCTAssertTrue(event.smartDenied)
    }

    /// A bot chat's approval carries the statement as its title.
    func testABotChatApprovalReadsItsTitle() {
        let bot = Message.Approval(
            runID: "r", title: "execute_code script execution", detail: nil,
            command: "execute_code <<'PY'", choices: [.once, .deny]
        )
        XCTAssertEqual(bot.hermesDescription, "execute_code script execution")
        let untitled = Message.Approval(runID: "r", title: "Approval needed", detail: nil,
                                        command: nil, choices: [.once, .deny])
        XCTAssertNil(untitled.hermesDescription)
    }

    func testANetworkErrorIsNotShownAsTheCommand() {
        let corrupted = AliceEvent(
            id: "run-approval:run-1:req-1", kind: .needsInput, severity: .needsAttention,
            title: "Needs your approval", summary: "…",
            detail: HermesClient.Failure.unreachable.errorDescription, occurred: Date(),
            reference: .init(transport: .gatewayRun, runID: "run-1", requestID: "req-1"),
            standing: .waiting
        )
        XCTAssertNil(AppStore.withoutMisplacedError(corrupted).detail)

        var real = corrupted
        real.detail = "rm -rf ./build"
        XCTAssertEqual(AppStore.withoutMisplacedError(real).detail, "rm -rf ./build")

        // Other kinds keep their detail: a failed automation's detail is its error.
        var failure = corrupted
        failure.kind = .automationFailed
        XCTAssertNotNil(AppStore.withoutMisplacedError(failure).detail)
    }

    // MARK: Asking Hermes

    private func client() async -> HermesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelListStub.self]
        let client = HermesClient(session: URLSession(configuration: config))
        await client.connect(to: .init(url: URL(string: "http://gateway.invalid/")!, key: "test-only"))
        return client
    }

    func testARunStillWaitingIsKept() async throws {
        ModelListStub.install(["v1/runs/run-1": .json(#"{"run_id":"run-1","status":"waiting_for_approval"}"#)])
        let waiting = try await client().runIsWaitingForApproval(runID: "run-1", profile: nil)
        XCTAssertTrue(waiting)
    }

    func testARunThatMovedOnOrWasForgottenIsNotWaiting() async throws {
        ModelListStub.install(["v1/runs/run-1": .json(#"{"run_id":"run-1","status":"completed"}"#)])
        let finished = try await client().runIsWaitingForApproval(runID: "run-1", profile: nil)
        XCTAssertFalse(finished)

        // No route in the stub is a 404, which is Hermes' run_not_found.
        ModelListStub.install([:])
        let forgotten = try await client().runIsWaitingForApproval(runID: "run-1", profile: nil)
        XCTAssertFalse(forgotten)
    }

    /// Not reaching Hermes is not evidence the request is over.
    func testAnUnansweredCheckDecidesNothing() async {
        ModelListStub.install(["v1/runs/run-1": .timeout])
        do {
            _ = try await client().runIsWaitingForApproval(runID: "run-1", profile: nil)
            XCTFail("a check that could not reach Hermes must throw")
        } catch {}
    }
}
