import XCTest
@testable import Alice

final class AppDiagnosticsTests: XCTestCase {
    func testTheDumpNeverCarriesAKeyOrAnAddress() {
        let snap = AppDiagnosticsSnapshot(
            deviceID: "phone-1",
            capturedAt: Date(timeIntervalSince1970: 1_789_500_000),
            version: "1.0",
            build: "2",
            revision: "abc12345",
            wellbeing: "well",
            connected: true,
            dashboardReady: true,
            gatewayConfigured: true,
            unknownEvents: ["runStream:foo ×1 id"],
            lines: ["turn.failed reply=r1 error=timeout"]
        )
        let body = snap.jsonObject()
        XCTAssertEqual(body["device_id"] as? String, "phone-1")
        XCTAssertEqual(body["wellbeing"] as? String, "well")
        XCTAssertNil(body["gateway_url"])
        XCTAssertNil(body["key"])
        XCTAssertNil(body["token"])
        XCTAssertEqual(body["lines"] as? [String], ["turn.failed reply=r1 error=timeout"])
    }

    func testTheChatSummarySaysWhenThePluginWasNotReached() {
        let snap = AppDiagnosticsSnapshot(
            deviceID: "phone-1",
            capturedAt: Date(),
            version: "1.0",
            build: "2",
            revision: nil,
            wellbeing: "unreachable",
            connected: false,
            dashboardReady: false,
            gatewayConfigured: true,
            unknownEvents: [],
            lines: []
        )
        let text = snap.chatSummary(uploaded: false)
        XCTAssertTrue(text.contains("unreachable"))
        XCTAssertTrue(text.contains("only on the phone"))
        XCTAssertFalse(text.contains("Copied to Hermes"))
    }
}
