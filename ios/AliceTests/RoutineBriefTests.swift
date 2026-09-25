import XCTest
@testable import Alice

/// A routine from a sentence: the when is found, the what is what is left.
final class RoutineBriefTests: XCTestCase {
    func testEveryMorningAtEightInSpanish() {
        let reading = RoutineBrief.read("cada mañana a las 8 dime el tiempo en Blanes")
        XCTAssertEqual(reading.cadence, .daily(hour: 8, minute: 0))
        XCTAssertEqual(reading.task, "Dime el tiempo en Blanes")
        XCTAssertEqual(reading.name, "El tiempo en Blanes")
    }

    func testEveryDayAtAnEveningTimeInEnglish() {
        let reading = RoutineBrief.read("Every day at 6:30pm summarize the news about Cuba")
        XCTAssertEqual(reading.cadence, .daily(hour: 18, minute: 30))
        XCTAssertEqual(reading.task, "Summarize the news about Cuba")
        XCTAssertEqual(RoutineBrief.read("cada 2 días riega las plantas").cadence, .interval(value: 2, unit: "d"))
    }

    func testAnAfternoonWithoutATimeGetsASensibleHour() {
        XCTAssertEqual(RoutineBrief.read("cada tarde resume mi correo").cadence, .daily(hour: 18, minute: 0))
        XCTAssertEqual(RoutineBrief.read("every night check the prices").cadence, .daily(hour: 21, minute: 0))
    }

    func testWeekdays() {
        XCTAssertEqual(RoutineBrief.read("entre semana a las 7:45 recuérdame el gimnasio").cadence, .weekdays(hour: 7, minute: 45))
        XCTAssertEqual(RoutineBrief.read("on weekdays at 9 send me my agenda").cadence, .weekdays(hour: 9, minute: 0))
    }

    func testNamedDays() {
        let reading = RoutineBrief.read("los lunes y jueves a las 9 busca ofertas de vuelos a Roma")
        guard case let .weekly(days, hour, minute)? = reading.cadence else {
            return XCTFail("expected a weekly cadence, got \(String(describing: reading.cadence))")
        }
        XCTAssertEqual(Set(days), [1, 4])
        XCTAssertEqual(hour, 9)
        XCTAssertEqual(minute, 0)
        XCTAssertEqual(reading.task, "Busca ofertas de vuelos a Roma")
        XCTAssertEqual(RoutineBrief.schedule(for: reading.cadence!), "every mon,thu at 09:00")
    }

    func testIntervals() {
        XCTAssertEqual(RoutineBrief.read("cada 2 horas mira si hay novedades").cadence, .interval(value: 2, unit: "h"))
        XCTAssertEqual(RoutineBrief.read("every 30 minutes check the server").cadence, .interval(value: 30, unit: "m"))
        XCTAssertEqual(RoutineBrief.read("every hour ping me").cadence, .interval(value: 1, unit: "h"))
        XCTAssertEqual(RoutineBrief.read("every hour ping me").task, "Ping me")
    }

    func testASentenceWithNoScheduleLeavesTheControlsAlone() {
        let reading = RoutineBrief.read("resume las noticias de tecnología")
        XCTAssertNil(reading.cadence)
        XCTAssertEqual(reading.task, "Resume las noticias de tecnología")
    }

    func testHermesScheduleWords() {
        XCTAssertEqual(RoutineBrief.schedule(for: .daily(hour: 8, minute: 5)), "every day at 08:05")
        XCTAssertEqual(RoutineBrief.schedule(for: .weekdays(hour: 9, minute: 0)), "weekdays at 09:00")
        XCTAssertEqual(RoutineBrief.schedule(for: .interval(value: 3, unit: "d")), "every 3d")
        XCTAssertEqual(RoutineBrief.describe(.weekly(days: [5, 1], hour: 9, minute: 0)), "Every Monday, Friday at 09:00")
        XCTAssertEqual(RoutineBrief.describe(.interval(value: 1, unit: "m")), "Every 1 minute")
    }

    func testADailyScheduleReadsBackTheSameCadence() {
        let cadence = RoutineBrief.Cadence.daily(hour: 8, minute: 5)
        XCTAssertEqual(
            RoutineBrief.cadence(fromHermesSchedule: RoutineBrief.schedule(for: cadence)),
            cadence
        )
    }

    func testAWeekdaysScheduleReadsBackTheSameCadence() {
        let cadence = RoutineBrief.Cadence.weekdays(hour: 9, minute: 0)
        XCTAssertEqual(
            RoutineBrief.cadence(fromHermesSchedule: RoutineBrief.schedule(for: cadence)),
            cadence
        )
    }

    func testAWeeklyScheduleReadsBackTheSameCadence() {
        let cadence = RoutineBrief.Cadence.weekly(days: [1, 4], hour: 9, minute: 0)
        XCTAssertEqual(RoutineBrief.schedule(for: cadence), "every mon,thu at 09:00")
        XCTAssertEqual(
            RoutineBrief.cadence(fromHermesSchedule: RoutineBrief.schedule(for: cadence)),
            cadence
        )
    }

    func testAnIntervalScheduleReadsBackTheSameCadence() {
        XCTAssertEqual(
            RoutineBrief.cadence(fromHermesSchedule: RoutineBrief.schedule(for: .interval(value: 2, unit: "h"))),
            .interval(value: 2, unit: "h")
        )
        XCTAssertEqual(
            RoutineBrief.cadence(fromHermesSchedule: RoutineBrief.schedule(for: .interval(value: 30, unit: "m"))),
            .interval(value: 30, unit: "m")
        )
        XCTAssertEqual(
            RoutineBrief.cadence(fromHermesSchedule: RoutineBrief.schedule(for: .interval(value: 3, unit: "d"))),
            .interval(value: 3, unit: "d")
        )
    }

    func testAFiveFieldDailyCronReadsAsDaily() {
        XCTAssertEqual(RoutineBrief.cadence(fromHermesSchedule: "5 8 * * *"), .daily(hour: 8, minute: 5))
    }

    func testSimpleWeekdayCronsReadAsWeekdaysOrNamedDays() {
        XCTAssertEqual(RoutineBrief.cadence(fromHermesSchedule: "0 9 * * 1-5"), .weekdays(hour: 9, minute: 0))
        XCTAssertEqual(
            RoutineBrief.cadence(fromHermesSchedule: "0 9 * * 1,4"),
            .weekly(days: [1, 4], hour: 9, minute: 0)
        )
    }

    func testEveryTemplateIsCompleteAndCheap() {
        for template in RoutineBrief.templates {
            XCTAssertFalse(template.name.isEmpty, template.id)
            XCTAssertFalse(template.prompt.isEmpty, template.id)
            XCTAssertLessThan(template.prompt.count, 400, "\(template.id): a long prompt costs on every run")
            XCTAssertFalse(RoutineBrief.schedule(for: template.cadence).isEmpty, template.id)
        }
        XCTAssertEqual(Set(RoutineBrief.templates.map(\.id)).count, RoutineBrief.templates.count)
    }
}
