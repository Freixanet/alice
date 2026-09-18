import XCTest
@testable import Alice

final class ModelConfirmationTests: XCTestCase {
    func testTheMetaContributorBannerIsANoticeNotAnAnswer() {
        let banner = """
        !!! CONTRIBUTOR TIER — TRAINS ON YOUR DATA !!!
        This is Meta's contributor tier. Selecting it permits Meta to use your
        prompts and completions to train future Meta models.
        """
        XCTAssertEqual(ModelConfirmation.notice(in: banner), banner)
        XCTAssertNotNil(ModelConfirmation.needed(from: ModelConfirmation.Needed(message: banner)))
    }

    func testAnOrdinaryReplyIsNotAPolicyNotice() {
        XCTAssertNil(ModelConfirmation.notice(in: "The model trains on public data in general."))
        XCTAssertNil(ModelConfirmation.notice(in: "API call failed: quota exceeded"))
        XCTAssertNil(ModelConfirmation.needed(from: HermesRPCClient.Failure(reason: "offline")))
    }

    func testAFailureCarryingTheBannerIsConfirmation() {
        let error = HermesRPCClient.Failure(reason: "!!! CONTRIBUTOR TIER — TRAINS ON YOUR DATA !!!")
        XCTAssertEqual(
            ModelConfirmation.needed(from: error)?.message,
            "!!! CONTRIBUTOR TIER — TRAINS ON YOUR DATA !!!"
        )
    }

    func testACompletionWithoutDeltasStillCarriesTheReply() {
        let done = AppStore.chatEvent(from: HermesRPCEvent(
            type: "message.complete", sessionID: "s1",
            payload: ["status": "complete", "text": "The sky is clear."]
        ))
        guard case let .run(_, status, output)? = done else {
            return XCTFail("a complete frame with text is the reply")
        }
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(output, "The sky is clear.")
        XCTAssertEqual(AppStore.replyBody(current: "", completion: output), "The sky is clear.")
    }

    func testAParentCompletionDoesNotWipeWhatStreamedBeforeATool() {
        XCTAssertEqual(
            AppStore.replyBody(
                current: "Looking into it. Here is what it found.",
                completion: "Here is what it found."
            ),
            "Looking into it. Here is what it found."
        )
    }

    func testAFallbackExhaustionNoticeIsAFailureNotAnAnswer() {
        let text = "⚠️ No reply: every provider in the fallback chain kept failing over, so the turn stopped instead of retrying forever. Send `continue` or switch provider."
        XCTAssertEqual(AppStore.agentFailure(in: text), text)
        XCTAssertTrue(AppStore.isNoReply(text))
        XCTAssertNil(AppStore.agentFailure(in: "No reply from the office until Monday."))
    }
}
