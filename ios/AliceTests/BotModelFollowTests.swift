import XCTest
@testable import Alice

/// Changing a bot's model in the picker has to change the model the bot runs —
/// including its routines. Hermes records, for each routine that follows the
/// bot, the model it was following, and refuses to run one whose record no
/// longer matches: Radar IA's daily report would have failed closed the
/// morning after its model changed.
final class BotModelFollowTests: XCTestCase {
    private func bot(_ model: String, provider: String) -> BotRow {
        BotRow(
            name: "radar-ia", displayName: "Radar IA", detail: "",
            model: model, provider: provider, skills: 0, isDefault: false,
            gatewayRunning: true, active: true
        )
    }

    private func job(
        _ id: String, model: String? = nil, provider: String? = nil,
        records model_snapshot: String? = nil, recordsProvider provider_snapshot: String? = nil,
        profile: String? = "radar-ia"
    ) -> JobRow {
        var row = JobRow(
            id: id, name: id, prompt: "", schedule: "0 10 * * *", enabled: true, profile: profile
        )
        row.model = model
        row.provider = provider
        row.modelSnapshot = model_snapshot
        row.providerSnapshot = provider_snapshot
        return row
    }

    private func changes(_ jobs: [JobRow]) -> [AppStore.RoutineModelChange] {
        AppStore.routineModelChanges(
            jobs,
            previousModel: "meta/muse-spark-1.3-contributor", previousProvider: "openrouter",
            newModel: "muse-spark-1.3-contributor-free", newProvider: "opencode-free"
        )
    }

    func testARoutineFollowingTheBotHasItsRecordRefreshed() {
        let report = job(
            "report", records: "meta/muse-spark-1.3-contributor", recordsProvider: "openrouter"
        )
        XCTAssertEqual(changes([report]), [.follow(id: "report", profile: "radar-ia")])
    }

    func testARoutineAlreadyRecordingTheNewModelIsLeftAlone() {
        let report = job(
            "report", records: "muse-spark-1.3-contributor-free", recordsProvider: "opencode-free"
        )
        XCTAssertEqual(changes([report]), [])
    }

    func testARoutinePinnedToTheOldModelMovesWithTheBot() {
        let pinned = job("pinned", model: "meta/muse-spark-1.3-contributor", provider: "openrouter")
        XCTAssertEqual(changes([pinned]), [.repin(id: "pinned", profile: "radar-ia")])
    }

    func testARoutinePinnedToAnotherModelKeepsIt() {
        let deliberate = job("deliberate", model: "stepfun/step-3.7-flash:free", provider: "nous")
        XCTAssertEqual(changes([deliberate]), [])
    }

    func testTheSameModelFromAnotherProviderIsAnotherModel() {
        let elsewhere = job("elsewhere", model: "meta/muse-spark-1.3-contributor", provider: "nous")
        XCTAssertEqual(changes([elsewhere]), [], "pinned to a different provider on purpose")
    }

    func testARoutineAlreadyPinnedToTheNewModelIsLeftAlone() {
        let done = job("done", model: "muse-spark-1.3-contributor-free", provider: "opencode-free")
        XCTAssertEqual(changes([done]), [])
    }

    func testARoutineWithNoProfileCannotBeAddressed() {
        let orphan = job("orphan", records: "meta/muse-spark-1.3-contributor", profile: nil)
        XCTAssertEqual(changes([orphan]), [])
    }

    func testASecondChangeUsesTheLiveCachedModelAsItsStartingPoint() {
        let stalePageRow = bot("model-a", provider: "provider-a")
        let liveRow = bot("model-b", provider: "provider-b")

        let transition = AppStore.modelSyncTransition(
            for: stalePageRow,
            cachedBots: [liveRow],
            model: "model-c",
            provider: "provider-c"
        )

        XCTAssertEqual(transition.previousModel, "model-b")
        XCTAssertEqual(transition.previousProvider, "provider-b")
        XCTAssertEqual(transition.model, "model-c")
        XCTAssertEqual(transition.provider, "provider-c")
    }

    func testACancelledPendingDoesNotApplyTheAbandonedModel() {
        let abandoned = AppStore.PendingBotModelSync(
            previousModel: "model-a", previousProvider: "provider-a",
            model: "model-b", provider: "provider-b"
        )
        let live = AppStore.PendingBotModelSync(
            previousModel: "model-b", previousProvider: "provider-b",
            model: "model-c", provider: "provider-c"
        )
        XCTAssertFalse(AppStore.shouldApplyModelCarry(abandoned, stillPending: live))
        XCTAssertTrue(AppStore.shouldApplyModelCarry(live, stillPending: live))
        XCTAssertFalse(AppStore.shouldApplyModelCarry(live, stillPending: nil))
    }

    func testANewChoiceStartsFromTheLiveCacheNotTheAbandonedPending() {
        let abandonedPage = bot("model-a", provider: "provider-a")
        let liveRow = bot("model-b", provider: "provider-b")
        let next = AppStore.modelSyncTransition(
            for: abandonedPage,
            cachedBots: [liveRow],
            model: "model-c",
            provider: "provider-c"
        )
        XCTAssertEqual(next.previousModel, "model-b", "the new sync starts from the cache, not the cancelled pending")
        XCTAssertEqual(next.model, "model-c")
    }
}
