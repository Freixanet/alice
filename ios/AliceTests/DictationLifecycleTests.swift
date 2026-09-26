import XCTest
@testable import Alice

@MainActor
final class DictationLifecycleTests: XCTestCase {
    func testPermissionReplyCannotRestartDictationAfterLeavingTheChat() async {
        let requested = expectation(description: "Permission requested")
        var reply: CheckedContinuation<Bool, Never>?
        let dictation = Dictation(permission: {
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        dictation.toggle { _ in XCTFail("A cancelled dictation must not write into any chat") }
        await fulfillment(of: [requested], timeout: 2)
        dictation.stop()
        reply?.resume(returning: false)
        await Task.yield()
        XCTAssertEqual(dictation.state, .idle)
    }
}
