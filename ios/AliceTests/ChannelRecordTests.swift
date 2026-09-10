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

    /// Reworded to "No messaging app has a problem now" it still read as an
    /// alert about nothing, so stored roll-up rows are dropped, both ways.
    func testStoredRollUpRecordsAreDropped() {
        func row(_ id: String) -> AliceEvent {
            AliceEvent(id: id, kind: .recovered, severity: .informational,
                       title: "Messaging apps", summary: "", occurred: Date())
        }
        XCTAssertTrue(AppStore.isChannelRollupRecord(row("component:platforms:ok")))
        XCTAssertTrue(AppStore.isChannelRollupRecord(row("component:platforms:degraded")))
        // A named component, and anything that is not a component, stay.
        XCTAssertFalse(AppStore.isChannelRollupRecord(row("component:telegram:connected")))
        XCTAssertFalse(AppStore.isChannelRollupRecord(row("attention:channel:whatsapp")))
        XCTAssertFalse(AppStore.isChannelRollupRecord(row("routine:default/job1:1789000000")))
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
