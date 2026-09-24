import XCTest
@testable import Alice

final class BriefingRemindersTests: XCTestCase {
    private func reminder(_ title: String, due: Date?, priority: Int = 0, completed: Bool = false) -> AgendaItem {
        AgendaItem(id: title, kind: .reminder(identifier: title, color: nil), title: title,
                   start: due, end: due, allDay: false, location: nil,
                   notes: "privado", priority: priority, list: "Casa", completed: completed)
    }

    func testTheMorningGetsWhatIsDueSoonOrUrgentAndNeverNotes() {
        let now = Date(timeIntervalSince1970: 1_790_060_400)
        let rows = AppStore.briefingReminders([
            reminder("Mañana", due: now.addingTimeInterval(24 * 3600)),
            reminder("Vencido", due: now.addingTimeInterval(-3 * 24 * 3600)),
            reminder("La semana que viene", due: now.addingTimeInterval(7 * 24 * 3600)),
            reminder("Urgente sin fecha", due: nil, priority: 3),
            reminder("Algún día", due: nil),
            reminder("Hecho", due: now, completed: true),
        ], now: now)
        XCTAssertEqual(rows.compactMap { $0["title"] as? String }, ["Vencido", "Mañana", "Urgente sin fecha"])
        XCTAssertTrue(rows.allSatisfy { $0["notes"] == nil })
        XCTAssertEqual(rows.first?["list"] as? String, "Casa")
    }
}
