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
}
