import XCTest
@testable import Alice

/// Activity filled up with identical rows: nine of "aviso-bateria-mac-15 —
/// This automation finished." one under another. Event ids carry a timestamp,
/// so every run is its own fact, which is right for the record and wrong for
/// a list.
final class ActivityStackingTests: XCTestCase {

    private func run(_ minutesAgo: Int, key: String = "default/job1") -> AliceEvent {
        let when = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        return AliceEvent(
            id: "routine:\(key):\(Int(when.timeIntervalSince1970))",
            kind: .automationSucceeded, severity: .informational,
            title: "aviso-bateria-mac-15", summary: "This automation finished.",
            occurred: when
        )
    }

    /// The rows that had piled up were written before routine events carried
    /// their key on the reference, so grouping cannot depend on it. The id
    /// alone has to be enough.
    func testRunsWithoutAReferenceStillStack() {
        let groups = ActivityGroup.stack([run(1), run(12), run(22), run(240)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 4)
        // The stack shows the newest.
        XCTAssertEqual(groups[0].latest.id, run(1).id)
    }

    /// With the reference present it must group the same way, or a restart
    /// would silently split a stack in two.
    func testReferenceAndIdAgreeOnTheSubject() {
        var withReference = run(5)
        withReference.reference = .init(profile: "default", routineKey: "default/job1")
        XCTAssertEqual(withReference.subject, run(5).subject)
    }

    /// Two automations are two rows, however similar they look.
    func testDifferentAutomationsDoNotMerge() {
        let groups = ActivityGroup.stack([
            run(1, key: "default/job1"), run(2, key: "radar-ia/job2"),
        ])
        XCTAssertEqual(groups.count, 2)
    }

    /// A component going bad and coming back is one subject, not two.
    func testComponentStatesShareASubject() {
        let bad = AliceEvent(
            id: "component:telegram:disconnected", kind: .attention,
            severity: .needsAttention, title: "Telegram", summary: "…", occurred: Date()
        )
        let good = AliceEvent(
            id: "component:telegram:connected", kind: .recovered,
            severity: .informational, title: "Telegram", summary: "…",
            occurred: Date().addingTimeInterval(-60)
        )
        let attention = AliceEvent(
            id: "attention:component:telegram", kind: .attention,
            severity: .needsAttention, title: "Telegram", summary: "…", occurred: Date()
        )
        XCTAssertEqual(Set([bad, good, attention].map(\.subject)).count, 1)
    }

    /// Each approval is its own decision. Stacking two would hide one behind
    /// the other's buttons, and answering the visible one would leave the
    /// hidden one still blocking the agent.
    func testRequestsAreNeverStacked() {
        let first = AliceEvent(
            id: "approval:r1", kind: .needsInput, severity: .needsAttention,
            title: "Needs your approval", summary: "…", occurred: Date(),
            reference: .init(requestID: "r1"), standing: .waiting
        )
        let second = AliceEvent(
            id: "approval:r2", kind: .needsInput, severity: .needsAttention,
            title: "Needs your approval", summary: "…", occurred: Date(),
            reference: .init(requestID: "r2"), standing: .waiting
        )
        XCTAssertEqual(ActivityGroup.stack([first, second]).count, 2)
    }

    /// Newest first, and a stack sits where its newest member would.
    func testOrderFollowsTheNewestMember() {
        let older = run(300, key: "default/a")
        let newer = run(2, key: "default/b")
        let groups = ActivityGroup.stack([older, run(400, key: "default/a"), newer])
        XCTAssertEqual(groups.map(\.latest.title.isEmpty), [false, false])
        XCTAssertEqual(groups[0].latest.id, newer.id)
        XCTAssertEqual(groups[1].count, 2)
    }

    /// Six chats with the same assistant are six sessions, and by the strict
    /// reading six subjects — which is how the screen ended up showing six
    /// identical "Alice — This task finished" rows. Read as words that is one
    /// thing that happened six times.
    func testFinishedTurnsGroupByAssistantNotBySession() {
        let turns = (1...6).map { index in
            AliceEvent(
                id: "turn:session-\(index):\(Int(Date().timeIntervalSince1970) - index)",
                kind: .finished, severity: .informational, profile: "default",
                title: "Alice", summary: "This task finished.",
                occurred: Date().addingTimeInterval(-Double(index))
            )
        }
        let groups = ActivityGroup.stack(turns)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 6)
    }

    /// The main chat is not a bot, so its completions carry no profile — and
    /// falling back to the run or session id put each one in a group of one.
    /// That is how six identical rows survived the first fix.
    func testFinishedTurnsWithoutAProfileStillGroup() {
        let runs = (1...6).map { index in
            AliceEvent(
                id: "run:run-\(index)", kind: .finished, severity: .informational,
                title: "Alice", summary: "This task finished.",
                occurred: Date().addingTimeInterval(-Double(index)),
                reference: .init(transport: .gatewayRun, runID: "run-\(index)")
            )
        }
        let groups = ActivityGroup.stack(runs)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 6)
    }

    /// Two different assistants stay two rows.
    func testFinishedTurnsFromDifferentAssistantsStaySeparate() {
        let mine = AliceEvent(
            id: "turn:a:1", kind: .finished, severity: .informational,
            profile: "default", title: "Alice", summary: "…", occurred: Date()
        )
        let radar = AliceEvent(
            id: "turn:b:2", kind: .finished, severity: .informational,
            profile: "radar-ia", title: "Radar IA", summary: "…", occurred: Date()
        )
        XCTAssertEqual(ActivityGroup.stack([mine, radar]).count, 2)
    }

    /// A failed send is a passing problem, not a new description of the
    /// request: it used to overwrite `detail`, so an approval card offered
    /// Once/Always over the text of a network error.
    func testTheRequestKeepsItsOwnWords() {
        var event = AliceEvent(
            id: "approval:r1", kind: .needsInput, severity: .needsAttention,
            title: "Needs your approval", summary: "Radar IA is waiting.",
            detail: "rm -rf build", occurred: Date(),
            reference: .init(requestID: "r1"), standing: .waiting
        )
        event.note = "That reply didn't reach Hermes."
        XCTAssertEqual(event.detail, "rm -rf build")
        XCTAssertEqual(event.summary, "Radar IA is waiting.")
        XCTAssertNotNil(event.note)
    }
    func testCurrentProblemIsNotRepeatedInHistoryAfterCopyChanges() {
        let current = AliceEvent(
            id: "attention:component:platforms", kind: .attention, severity: .needsAttention,
            title: "Messaging apps", summary: "Some messaging apps are unavailable.",
            detail: "degraded", occurred: Date(timeIntervalSince1970: 300)
        )
        let historical = AliceEvent(
            id: "component:platforms:degraded", kind: .attention, severity: .needsAttention,
            title: "platforms", summary: "platforms needs attention.",
            detail: "degraded", occurred: Date(timeIntervalSince1970: 200)
        )
        let sections = ActivityPresentation.partition(
            attention: [current], activity: [historical]
        )
        XCTAssertEqual(sections.needsAttention.map(\.id), [current.id])
        XCTAssertTrue(sections.history.isEmpty)
    }

}
