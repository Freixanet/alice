import XCTest
@testable import Alice

final class RadarIATests: XCTestCase {
    func testRadarIsARealBotTemplate() {
        XCTAssertEqual(RadarIA.botName, "radar-ia")
        XCTAssertEqual(RadarIA.displayName, "Radar IA")
        XCTAssertTrue(RadarIA.ownsSoul(RadarIA.editorialPrompt))
    }

    func testDetectsHermesBootstrapSoulWithoutMatchingCustomInstructions() {
        XCTAssertTrue(RadarIA.isGenericHermesSoul(
            "You are Hermes Agent, built by Nous Research. Be direct."
        ))
        XCTAssertFalse(RadarIA.isGenericHermesSoul(RadarIA.editorialPrompt))
        XCTAssertFalse(RadarIA.isGenericHermesSoul(
            "You are Radar IA. Keep my custom editorial preferences."
        ))
    }

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

    func testSetupPromptPreservesBotAndSchedulerBoundaries() throws {
        let prompt = try XCTUnwrap(
            RadarIA.setupPrompt(time: "08:45", zone: "America/New_York")
        )
        XCTAssertTrue(prompt.contains("perfil real de Hermes `radar-ia`"))
        XCTAssertTrue(prompt.contains("No crees otro perfil"))
        XCTAssertTrue(prompt.contains("08:45"))
        XCTAssertTrue(prompt.contains("America/New_York"))
        XCTAssertTrue(prompt.contains("no crees duplicados"))
        XCTAssertTrue(prompt.contains("No inventes un campo `timezone`"))
        XCTAssertTrue(prompt.contains("`CRON_TZ`"))
        XCTAssertTrue(prompt.contains("UNA rutina propiedad de `radar-ia`"))
        XCTAssertTrue(prompt.contains("fuentes actuales"))
    }

    func testSetupPromptRejectsFixedOffsetZone() {
        XCTAssertNil(RadarIA.setupPrompt(time: "10:00", zone: "UTC+02:00"))
    }
}
