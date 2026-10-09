import XCTest
@testable import Alice

@MainActor
final class ChatRecoveryTests: XCTestCase {
    func testChatFinishesWhileGatewayCatalogueIsStillLoading() async {
        var gatewayFinished = false
        var historyRead = false
        var gatewayWaiter: CheckedContinuation<Void, Never>?
        var gatewayStarted = false
        let recovery = Task {
            await ChatRecovery.run(gateway: {
                gatewayStarted = true
                await withCheckedContinuation { gatewayWaiter = $0 }
                gatewayFinished = true
            }, chat: {
                XCTAssertFalse(gatewayFinished)
                historyRead = true
            })
        }
        while !gatewayStarted { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(historyRead, "Saved chat messages must not wait for the model catalogue")
        XCTAssertFalse(gatewayFinished)
        gatewayWaiter?.resume()
        await recovery.value
        XCTAssertTrue(gatewayFinished)
        XCTAssertTrue(historyRead)
    }
}
