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

    func testVoicePermissionReplyCannotResumeAnEndedConversation() async throws {
        let suite = "alice.voice-lifecycle-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requested = expectation(description: "Voice permission requested")
        var reply: CheckedContinuation<Bool, Never>?
        let voice = VoiceConversation(permission: {
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        let store = AppStore(defaults: defaults)
        voice.begin(store: store)
        await fulfillment(of: [requested], timeout: 2)
        voice.end()
        reply?.resume(returning: false)
        await Task.yield()
        XCTAssertEqual(voice.phase, .paused)
    }
}
