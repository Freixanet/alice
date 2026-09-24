import XCTest
@testable import Alice

final class PlaceTriggerTests: XCTestCase {
    func testATriggerFromHermesAndItsMonitorName() throws {
        let trigger = try XCTUnwrap(PlaceTrigger([
            "id": "pl_1", "profile": "default", "place": "Mercadona, Súria", "when": "arrive", "radius": 200,
        ]))
        XCTAssertFalse(trigger.isResolved)
        XCTAssertEqual(trigger.radius, 200)
        let parsed = try XCTUnwrap(PlaceTrigger.parse(key: trigger.monitorKey))
        XCTAssertEqual(parsed.profile, "default")
        XCTAssertEqual(parsed.id, "pl_1")
        XCTAssertNil(PlaceTrigger(["id": "x", "place": "Casa", "when": "sometime"]))
        XCTAssertNil(PlaceTrigger.parse(key: "no-separator"))
    }
}
