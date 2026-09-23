import XCTest
@testable import Alice

final class HomeSuggestionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWaitingComesBeforeAFailedRoutineAndClaimsThatChat() {
        let waiting = AliceEvent(
            id: "w", kind: .needsInput, severity: .needsAttention,
            title: "Approve the folder", summary: "Inbox asked",
            occurred: now.addingTimeInterval(-30),
            reference: .init(conversationID: "chat-1"),
            standing: .waiting
        )
        let failed = AliceEvent(
            id: "f", kind: .automationFailed, severity: .failure,
            title: "Morning briefing failed", summary: "rate limit",
            occurred: now.addingTimeInterval(-3600)
        )
        let rows = HomeSuggestions.make(
            events: [failed, waiting], now: now
        )
        XCTAssertEqual(rows.map(\.id), ["waiting", "routines-failed"])
        XCTAssertEqual(rows[0].action, .conversation("chat-1"))
    }

    func testARequestThatIsNotStillWaitingStaysQuiet() {
        let idle = AliceEvent(
            id: "s", kind: .needsInput, severity: .needsAttention,
            title: "Scout", summary: "last turn was the person",
            occurred: now.addingTimeInterval(-600),
            standing: .none
        )
        XCTAssertTrue(HomeSuggestions.make(events: [idle], now: now).isEmpty)
    }

    func testAnOpenQuestionAndHeavyUsageStayBehindMoreUrgentRows() {
        let failed = (1...2).map { index in
            AliceEvent(
                id: "f\(index)", kind: .automationFailed, severity: .failure,
                title: "Job \(index)", summary: "failed",
                occurred: now.addingTimeInterval(-1000)
            )
        }
        let rows = HomeSuggestions.make(
            events: failed,
            questions: [HomeNotePrompt(id: "n", label: "Which date?")],
            recentTokens: 3_000_000,
            now: now
        )
        XCTAssertEqual(rows.map(\.id), ["routines-failed", "question-n", "usage"])
        XCTAssertEqual(rows[0].title, "2 routines need a look")
    }

    func testABriefingIsSuggestedOnlyWhenTheRoutineListIsKnownAndEmptyOfOne() {
        XCTAssertTrue(HomeSuggestions.make(routineNames: nil, now: now).isEmpty)
        XCTAssertEqual(
            HomeSuggestions.make(routineNames: ["Deals"], now: now).map(\.id),
            ["briefing"]
        )
        XCTAssertTrue(HomeSuggestions.make(routineNames: ["Morning briefing"], now: now).isEmpty)
    }

    func testAResolvedRequestAndAnOldFailureStayQuiet() {
        let resolved = AliceEvent(
            id: "w", kind: .needsInput, severity: .needsAttention,
            title: "Done", summary: "answered",
            occurred: now, standing: .resolved
        )
        let old = AliceEvent(
            id: "f", kind: .automationFailed, severity: .failure,
            title: "Old", summary: "failed",
            occurred: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        XCTAssertTrue(HomeSuggestions.make(events: [resolved, old], now: now).isEmpty)
    }

    func testOneFailedRoutineOpensItsAgentsChat() {
        let failed = AliceEvent(
            id: "r", kind: .automationFailed, severity: .failure, profile: "radar-ia",
            title: "Radar IA — informe diario", summary: "rate limit",
            occurred: now.addingTimeInterval(-600)
        )
        XCTAssertEqual(HomeSuggestions.make(events: [failed], now: now).first?.action, .agent("radar-ia"))
        let alices = AliceEvent(
            id: "a", kind: .automationFailed, severity: .failure, profile: "default",
            title: "Buenos días", summary: "", occurred: now.addingTimeInterval(-600)
        )
        XCTAssertEqual(HomeSuggestions.make(events: [alices], now: now).first?.action, .today)
        XCTAssertEqual(HomeSuggestions.make(events: [failed, alices], now: now).first?.action, .routines)
    }

    func testAFailureFollowedByASuccessfulRunStaysQuiet() {
        let reference = AliceEvent.Reference(profile: "radar-ia", routineKey: "radar-ia/c3cf")
        let failed = AliceEvent(
            id: "f", kind: .automationFailed, severity: .failure, profile: "radar-ia",
            title: "Radar IA — informe diario", summary: "rate limit",
            occurred: now.addingTimeInterval(-2 * 24 * 60 * 60), reference: reference
        )
        let fine = AliceEvent(
            id: "ok", kind: .automationSucceeded, severity: .informational, profile: "radar-ia",
            title: "Radar IA — informe diario", summary: "finished",
            occurred: now.addingTimeInterval(-600), reference: reference
        )
        XCTAssertTrue(HomeSuggestions.make(events: [failed, fine], now: now).isEmpty)
        // A success before the failure, or of another routine, does not settle it.
        var earlier = fine
        earlier.occurred = now.addingTimeInterval(-3 * 24 * 60 * 60)
        XCTAssertEqual(HomeSuggestions.make(events: [failed, earlier], now: now).first?.id, "routines-failed")
        var other = fine
        other.reference = AliceEvent.Reference(profile: "radar-ia", routineKey: "radar-ia/other")
        XCTAssertEqual(HomeSuggestions.make(events: [failed, other], now: now).first?.id, "routines-failed")
    }
}
