import XCTest
@testable import Alice

/// After WhatsApp was switched off, Recent read "Messaging apps is working
/// again" — about no app in particular, and as if something had been repaired.
final class ChannelRecordTests: XCTestCase {

    func testTheChannelRollUpRecoveryIsSaidPlainly() {
        XCTAssertEqual(
            EventDigest.recovery(for: "platforms", label: "Messaging apps"),
            "No messaging app has a problem now."
        )
        // Anything else keeps its own name.
        XCTAssertEqual(EventDigest.recovery(for: "telegram", label: "Telegram"), "Telegram is working again.")
    }

    func testStoredRollUpRecoveriesAreReworded() {
        let stored = AliceEvent(
            id: "component:platforms:ok", kind: .recovered, severity: .informational,
            title: "Messaging apps", summary: "Messaging apps is working again.", occurred: Date()
        )
        XCTAssertEqual(AppStore.withCurrentWording(stored).summary, "No messaging app has a problem now.")
    }

    /// With each channel named, the roll-up's changes stay out of the record.
    func testTheRollUpLeavesTheRecordWhenChannelsAreKnown() throws {
        let components = [
            HermesSystemComponent(name: "platforms", status: "ok"),
            HermesSystemComponent(name: "gateway", status: "ok"),
        ]
        XCTAssertEqual(EventDigest.digestComponents(components, channelsKnown: true).map(\.name), ["gateway"])
        XCTAssertEqual(EventDigest.digestComponents(components, channelsKnown: false).map(\.name), ["platforms", "gateway"])

        var marks = EventWatermarks()
        marks.primed = true
        marks.componentStatus["platforms"] = "degraded"
        let recorded = EventDigest.digest(
            routines: [],
            components: EventDigest.digestComponents(components, channelsKnown: true),
            since: marks
        ).events
        XCTAssertTrue(recorded.isEmpty)
    }
}
