import XCTest
@testable import Alice

final class RadarIATests: XCTestCase {
    func testRadarIsARealBotTemplate() {
        XCTAssertEqual(RadarIA.botName, "radar-ia")
        XCTAssertEqual(RadarIA.displayName, "Radar IA")
        XCTAssertEqual(RadarIA.templateVersion, 1)
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

    func testScheduleUsesHermesNativeDailySyntax() {
        XCTAssertEqual(RadarIA.schedule(at: "08:45"), "every day at 08:45")
    }

    func testManagedRoutineDetectionDoesNotClaimAnUnrelatedCustomRoutine() {
        let official = JobRow(
            id: "one", name: RadarIA.routineName, prompt: RadarIA.editorialPrompt,
            schedule: "every day at 10:00", enabled: true, lastStatus: nil,
            lastError: nil, lastRun: nil, nextRun: nil, profile: RadarIA.botName
        )
        let legacy = JobRow(
            id: "two", name: "Daily briefing", prompt: RadarIA.editorialPrompt,
            schedule: "0 10 * * *", enabled: true, lastStatus: nil,
            lastError: nil, lastRun: nil, nextRun: nil, profile: RadarIA.botName
        )
        let custom = JobRow(
            id: "three", name: RadarIA.routineName, prompt: "Summarize my inbox",
            schedule: "every day at 10:00", enabled: true, lastStatus: nil,
            lastError: nil, lastRun: nil, nextRun: nil, profile: RadarIA.botName
        )
        XCTAssertTrue(RadarIA.manages(official))
        XCTAssertTrue(RadarIA.manages(legacy))
        XCTAssertTrue(RadarIA.manages(custom), "the installer must surface the name collision")
        XCTAssertFalse(RadarIA.ownsSoul(custom.prompt), "the collision must not be overwritten")

        var renamedCustomization = custom
        renamedCustomization.name = "My custom AI report"
        renamedCustomization.prompt = "Eres Radar IA, pero sigue mis reglas privadas."
        XCTAssertFalse(
            RadarIA.manages(renamedCustomization),
            "a phrase match must not claim a user-authored routine"
        )
    }
}
