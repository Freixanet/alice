import XCTest
@testable import Alice

final class DashboardRestorePolicyTests: XCTestCase {
    func testForegroundRestoreKeepsTheSameDashboardTransport() throws {
        let saved = try XCTUnwrap(URL(string: "http://100.67.213.42:9119/"))
        XCTAssertFalse(AppStore.dashboardEndpointChanged(from: saved, to: saved))
        XCTAssertTrue(AppStore.dashboardEndpointChanged(from: nil, to: saved))
        XCTAssertTrue(AppStore.dashboardEndpointChanged(
            from: URL(string: "http://100.67.213.43:9119/"), to: saved
        ))
    }
}
