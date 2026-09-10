import XCTest
@testable import Alice

/// A dismissed alert came back a few seconds later, because current problems
/// are read again on every sync and dismissing only removed the row from a list
/// that the next read rebuilt. Dismissal now holds while the problem is the same
/// and lets go when it changes.
final class AttentionDismissalTests: XCTestCase {

    private func whatsapp(_ state: String = "fatal", code: String? = "whatsapp_not_paired") -> [AliceEvent] {
        EventDigest.attention(
            routines: [], components: [],
            platforms: [HermesPlatformHealth(
                key: "whatsapp", profile: "default", platform: "whatsapp", state: state,
                errorCode: code, errorMessage: code.map { _ in "WhatsApp enabled but not paired" }
            )]
        )
    }

    private func failing(lastRun: Date) -> [AliceEvent] {
        EventDigest.attention(routines: [JobRow(
            id: "job1", name: "Limpieza", prompt: "", schedule: "", enabled: true,
            lastStatus: "error", lastError: "boom", lastRun: lastRun, nextRun: nil, profile: "default"
        )], components: [])
    }

    private func dismiss(_ items: [AliceEvent]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, EventDigest.fingerprint($0)) })
    }

    func testADismissedAlertStaysHiddenOnTheNextRead() {
        let dismissed = dismiss(whatsapp())
        // The next sync builds the same alert from scratch, with a new time.
        let next = EventDigest.visible(whatsapp(), dismissed: dismissed, completeReading: true)
        XCTAssertTrue(next.shown.isEmpty)
        XCTAssertEqual(next.dismissed, dismissed)
    }

    func testAChannelThatChangesComesBack() {
        let dismissed = dismiss(whatsapp())
        let next = EventDigest.visible(
            whatsapp("disconnected", code: nil), dismissed: dismissed, completeReading: true
        )
        XCTAssertEqual(next.shown.map(\.title), ["WhatsApp"])
    }

    func testAnAutomationFailingAgainComesBack() {
        let first = Date(timeIntervalSince1970: 1_789_000_000)
        let dismissed = dismiss(failing(lastRun: first))
        XCTAssertTrue(EventDigest.visible(failing(lastRun: first), dismissed: dismissed,
                                          completeReading: true).shown.isEmpty)
        let again = EventDigest.visible(failing(lastRun: first.addingTimeInterval(86_400)),
                                        dismissed: dismissed, completeReading: true)
        XCTAssertEqual(again.shown.count, 1)
    }

    /// Fixed, then broken again later in the same way: that is news.
    func testAResolvedProblemIsForgotten() {
        let dismissed = dismiss(whatsapp())
        let resolved = EventDigest.visible([], dismissed: dismissed, completeReading: true)
        XCTAssertTrue(resolved.dismissed.isEmpty)
        let recurred = EventDigest.visible(whatsapp(), dismissed: resolved.dismissed, completeReading: true)
        XCTAssertEqual(recurred.shown.count, 1)
    }

    /// A partial reading cannot say a problem is gone.
    func testAPartialReadingForgetsNothing() {
        let dismissed = dismiss(whatsapp())
        let partial = EventDigest.visible([], dismissed: dismissed, completeReading: false)
        XCTAssertEqual(partial.dismissed, dismissed)
    }

    func testSomethingWaitingOnAnAnswerIsNeverHidden() {
        let approval = AliceEvent(
            id: "approval:req-1", kind: .needsInput, severity: .needsAttention,
            title: "Alice", summary: "Wants to run a command", occurred: Date(),
            reference: .init(requestID: "req-1"), standing: .waiting
        )
        let shown = EventDigest.visible(
            [approval], dismissed: [approval.id: EventDigest.fingerprint(approval)], completeReading: true
        ).shown
        XCTAssertEqual(shown.map(\.id), [approval.id])
    }
}
