import XCTest
@testable import Alice

/// A bot's settings page changed its model whenever its picker changed —
/// including every time the page set the picker itself. For a model Hermes
/// asks to confirm, Meta's contributor tier, that asked forever: Cancel put
/// the current model back, and that asked again.
final class BotModelChoiceTests: XCTestCase {
    private func option(
        _ id: String, _ provider: String? = "openrouter"
    ) -> HermesClient.ModelOption {
        HermesClient.ModelOption(id: id, label: id, provider: provider, providerName: nil)
    }

    func testThePinnedModelIsNotAChange() {
        XCTAssertFalse(BotDetail.BotModelChoice.isChange(
            option("meta/muse-spark-1.3-contributor"),
            from: "meta/muse-spark-1.3-contributor", provider: "openrouter"
        ))
    }

    func testADifferentModelIsAChange() {
        XCTAssertTrue(BotDetail.BotModelChoice.isChange(
            option("x-ai/grok-4.6"),
            from: "meta/muse-spark-1.3-contributor", provider: "openrouter"
        ))
    }

    func testTheSameModelFromAnotherProviderIsAChange() {
        XCTAssertTrue(BotDetail.BotModelChoice.isChange(
            option("stepfun/step-3.7-flash:free", "openrouter"),
            from: "stepfun/step-3.7-flash:free", provider: "nous"
        ))
    }

    func testAPinThatNamesNoProviderMatchesOnTheModel() {
        XCTAssertFalse(BotDetail.BotModelChoice.isChange(
            option("meta/muse-spark-1.3-contributor"),
            from: "meta/muse-spark-1.3-contributor", provider: nil
        ))
    }

    func testWithNothingPinnedAnyPickIsAChange() {
        XCTAssertTrue(BotDetail.BotModelChoice.isChange(
            option("meta/muse-spark-1.3-contributor"), from: nil, provider: nil
        ))
    }
}
