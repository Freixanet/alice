import XCTest
@testable import Alice

/// The manifest is remote data. These are the cases where treating it as
/// instructions would have handed the gateway key to somebody else.
final class GatewayOriginTests: XCTestCase {
    private let base = URL(string: "http://10.0.0.2:8642")!

    func testKeepsOrdinaryRoutes() {
        XCTAssertEqual(GatewayOrigin.relativeRoute("api/skills"), "api/skills")
        XCTAssertEqual(GatewayOrigin.relativeRoute("/v1/models"), "/v1/models")
    }

    func testRefusesRoutesThatCarryAnOriginOfTheirOwn() {
        XCTAssertNil(GatewayOrigin.relativeRoute("https://different.example.test/collect"))
        XCTAssertNil(GatewayOrigin.relativeRoute("http://evil.test/x"))
        XCTAssertNil(GatewayOrigin.relativeRoute("//evil.test/x"))
        XCTAssertNil(GatewayOrigin.relativeRoute("javascript:alert(1)"))
        XCTAssertNil(GatewayOrigin.relativeRoute("data:text/plain,hi"))
    }

    func testRefusesRoutesThatClimbOutOrHideThings() {
        XCTAssertNil(GatewayOrigin.relativeRoute("api/../../etc"))
        XCTAssertNil(GatewayOrigin.relativeRoute("   "))
        XCTAssertNil(GatewayOrigin.relativeRoute("api/x\nHost: evil"))
    }

    func testOriginComparisonCoversSchemeHostAndPort() {
        XCTAssertTrue(GatewayOrigin.sameOrigin(URL(string: "http://10.0.0.2:8642/v1/x")!, as: base))
        XCTAssertFalse(GatewayOrigin.sameOrigin(URL(string: "http://evil.test:8642/v1/x")!, as: base))
        XCTAssertFalse(GatewayOrigin.sameOrigin(URL(string: "http://10.0.0.2:9119/v1/x")!, as: base))
        XCTAssertFalse(GatewayOrigin.sameOrigin(URL(string: "https://10.0.0.2:8642/v1/x")!, as: base))
    }

    func testDefaultPortsAndHostCase() {
        XCTAssertTrue(GatewayOrigin.sameOrigin(
            URL(string: "https://host.test/x")!, as: URL(string: "https://host.test:443")!))
        XCTAssertTrue(GatewayOrigin.sameOrigin(
            URL(string: "http://HOST.test:80/x")!, as: URL(string: "http://host.test")!))
    }
}
