import XCTest
@testable import Alice

final class RadarIATests: XCTestCase {
    func testDefaultScheduleMatchesProposal() {
        XCTAssertEqual(RadarIA.defaultTime, "10:00")
        XCTAssertEqual(RadarIA.defaultZone, "Europe/Madrid")
        XCTAssertTrue(RadarIA.validSchedule(time: "10:00", zone: "Europe/Madrid"))
    }

    func testRejectsInvalidOrFixedOffsetSchedule() {
        XCTAssertFalse(RadarIA.validSchedule(time: "24:00", zone: "Europe/Madrid"))
        XCTAssertFalse(RadarIA.validSchedule(time: "10:00", zone: "UTC+02:00"))
        XCTAssertFalse(RadarIA.validSchedule(time: "10:00", zone: "Not/AZone"))
    }

    func testSetupPromptPreservesSafetyBoundary() throws {
        let prompt = try XCTUnwrap(
            RadarIA.setupPrompt(time: "08:45", zone: "America/New_York")
        )
        XCTAssertTrue(prompt.contains("08:45"))
        XCTAssertTrue(prompt.contains("America/New_York"))
        XCTAssertTrue(prompt.contains("no crees duplicados"))
        XCTAssertTrue(prompt.contains("Verifica un destino que pueda leer desde Alice"))
        XCTAssertTrue(prompt.contains("INSTRUCCIONES EDITORIALES DE LA RUTINA"))
        XCTAssertTrue(prompt.contains("fuentes actuales"))
    }
}
