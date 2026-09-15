import XCTest
@testable import Alice

/// Notes as the Alice plugin serves them from an agent's notes store.
final class NotesFeedTests: XCTestCase {
    func testTheStoreIsReadWithTheAgentsReadingOfEachNote() throws {
        let snapshot = try NotesFeed.snapshot(from: [
            "available": true, "profile": "inbox", "total": 2,
            "notes": [
                ["id": "n2", "ts": "2026-09-14T10:00:00+02:00", "text": "Llamar al banco",
                 "types": ["tarea"], "topics": [], "processed": false],
                ["id": "n1", "ts": "2026-09-14T09:00:00+02:00", "text": "Idea: notas en Alice",
                 "types": ["idea"], "topics": ["alice"], "summary": "Notas", "processed": true,
                 "open_questions": ["¿Dónde?"], "urls": ["https://example.com"]],
                ["text": "no id"],
            ],
        ])
        XCTAssertTrue(snapshot.available)
        XCTAssertEqual(snapshot.agent, "inbox")
        XCTAssertEqual(snapshot.notes.map(\.id), ["n2", "n1"])
        XCTAssertEqual(snapshot.notes[1].topics, ["alice"])
        XCTAssertEqual(snapshot.notes[1].openQuestions, ["¿Dónde?"])
        XCTAssertTrue(snapshot.notes[1].processed)
        XCTAssertEqual(snapshot.notes[0].createdAt, Date(timeIntervalSince1970: 1_789_372_800))
    }

    func testNoStoreIsAnAnswerAndAMalformedReplyIsNot() throws {
        let none = try NotesFeed.snapshot(from: ["available": false, "notes": [], "total": 0])
        XCTAssertFalse(none.available)
        XCTAssertNil(none.agent)
        XCTAssertThrowsError(try NotesFeed.snapshot(from: ["notes": []]))
    }

    func testNotesAreGroupedByWhenTheyWereWritten() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let now = NotesFeed.date("2026-09-15T12:00:00+02:00")!
        func note(_ id: String, _ ts: String) -> Note {
            Note(id: id, createdAt: NotesFeed.date(ts), text: id)
        }
        let groups = NotesFeed.groups([
            note("old", "2026-08-01T10:00:00+02:00"),
            note("today", "2026-09-15T08:00:00+02:00"),
            note("week", "2026-09-11T08:00:00+02:00"),
            note("yesterday", "2026-09-14T23:30:00+02:00"),
            note("today-later", "2026-09-15T11:00:00+02:00"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "This week", "Earlier"])
        XCTAssertEqual(groups[0].notes.map(\.id), ["today-later", "today"])
    }

    func testSearchFindsWordsAndHowANoteWasSorted() {
        let note = Note(id: "1", createdAt: nil, text: "Comprar pan", types: ["tarea"], topics: ["casa"])
        XCTAssertTrue(NotesFeed.matches(note, query: "pan"))
        XCTAssertTrue(NotesFeed.matches(note, query: "task"))
        XCTAssertTrue(NotesFeed.matches(note, query: "CASA"))
        XCTAssertTrue(NotesFeed.matches(note, query: "  "))
        XCTAssertFalse(NotesFeed.matches(note, query: "banco"))
    }
}
