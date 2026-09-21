import XCTest
@testable import Alice

/// Recent showed an orange "Platforms needs attention" with nothing under Needs
/// attention: a row stored by an older build, in that build's words, drawn as
/// though it were current. The words are brought up to date on load.
final class ActivityRecordTests: XCTestCase {

    private func stored(id: String, title: String, summary: String) -> AliceEvent {
        AliceEvent(
            id: id, kind: .attention, severity: .needsAttention,
            title: title, summary: summary, occurred: Date()
        )
    }

    func testALegacyComponentRowGetsCurrentWording() {
        let legacy = stored(id: "component:platforms:degraded", title: "Platforms", summary: "needs attention")
        let repaired = AppStore.withCurrentWording(legacy)
        XCTAssertEqual(repaired.title, "Messaging apps")
        XCTAssertEqual(repaired.summary, EventDigest.consequence(for: "platforms"))
        XCTAssertEqual(repaired.id, legacy.id)
    }

    func testARecoveryIsWordedAsOne() {
        let legacy = stored(id: "component:telegram:connected", title: "telegram", summary: "is ok")
        XCTAssertEqual(AppStore.withCurrentWording(legacy).summary, "Telegram is working again.")
    }

    /// Matches what a new row gets, so old and new read the same.
    func testRepairedWordingMatchesANewRow() throws {
        var marks = EventWatermarks()
        marks.primed = true
        marks.componentStatus["platforms"] = "ok"
        let fresh = try XCTUnwrap(EventDigest.digest(
            routines: [],
            components: [HermesSystemComponent(name: "platforms", status: "degraded")],
            since: marks
        ).events.first)
        let legacy = stored(id: fresh.id, title: "Platforms", summary: "needs attention")
        let repaired = AppStore.withCurrentWording(legacy)
        XCTAssertEqual(repaired.title, fresh.title)
        XCTAssertEqual(repaired.summary, fresh.summary)
    }

    func testARoutineNoticeBelongsOnRoutines() {
        var event = AliceEvent(
            id: "run", kind: .automationSucceeded, severity: .info,
            title: "Morning", summary: "Finished.", occurred: Date()
        )
        event.reference.routineKey = "default/morning"
        XCTAssertEqual(event.noticePlace, .routines)
    }

    func testAnAgentNoticeBelongsOnAgents() {
        let event = AliceEvent(
            id: "done", kind: .finished, severity: .info,
            profile: "radar", title: "Radar", summary: "Answered.", occurred: Date()
        )
        XCTAssertEqual(event.noticePlace, .agents)
    }

    func testAComponentNoticeStaysInTheLog() {
        let event = AliceEvent(
            id: "attention:component:telegram", kind: .attention, severity: .needsAttention,
            title: "Telegram", summary: "Telegram is not connected.", occurred: Date()
        )
        XCTAssertNil(event.noticePlace)
    }

    func testOtherRowsAreLeftAlone() {
        let routine = AliceEvent(
            id: "routine:default/job1:1789000000", kind: .automationFailed, severity: .failure,
            title: "limpieza-semanal", summary: "This automation did not finish.", occurred: Date()
        )
        XCTAssertEqual(AppStore.withCurrentWording(routine), routine)
    }
}
