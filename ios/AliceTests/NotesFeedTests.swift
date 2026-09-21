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

    func testAMissingStoreIsNotTheSameAsTheDashboardBeingUnreachable() {
        XCTAssertEqual(NotesAccess.from(snapshot: NotesSnapshot(available: false, agent: nil, notes: [])), .noStore)
        XCTAssertEqual(NotesAccess.from(snapshot: NotesSnapshot(available: true, agent: "inbox", notes: [])), .ready)
        XCTAssertEqual(NotesAccess.from(error: DashboardClient.Failure.unreachable), .offline)
        XCTAssertEqual(NotesAccess.from(error: DashboardClient.Failure.timedOut), .offline)
        XCTAssertEqual(NotesAccess.from(error: DashboardClient.Failure.http(401, detail: nil)), .unauthorized)
        XCTAssertEqual(NotesAccess.from(error: DashboardClient.Failure.http(404, detail: nil)), .pluginMissing)
        XCTAssertEqual(NotesAccess.from(error: DashboardClient.Failure.notConfigured), .notConfigured)
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

    // MARK: - Sort By, and Group By Date

    private func stamped(_ id: String, created: String, edited: String? = nil, text: String? = nil) -> Note {
        var note = Note(id: id, createdAt: NotesFeed.date(created), text: text ?? id)
        note.editedAt = NotesFeed.date(edited)
        return note
    }

    func testSortByTitleReadsTheWayNamesAreSorted() {
        let notes = [
            stamped("1", created: "2026-09-01T10:00:00+02:00", text: "banco"),
            stamped("2", created: "2026-09-02T10:00:00+02:00", text: "Árbol"),
            stamped("3", created: "2026-09-03T10:00:00+02:00", text: "Casa"),
        ]
        XCTAssertEqual(
            NotesFeed.ordered(notes, by: .title).map { NotesFeed.title(of: $0) },
            ["Árbol", "banco", "Casa"]
        )
    }

    func testSortByDateEditedPutsAnOldNoteJustEditedFirst() {
        let notes = [
            stamped("new", created: "2026-09-14T10:00:00+02:00"),
            stamped("old-but-edited", created: "2026-08-01T10:00:00+02:00",
                    edited: "2026-09-15T10:00:00+02:00"),
        ]
        XCTAssertEqual(NotesFeed.ordered(notes, by: .dateEdited).map(\.id),
                       ["old-but-edited", "new"])
        XCTAssertEqual(NotesFeed.ordered(notes, by: .dateCreated).map(\.id),
                       ["new", "old-but-edited"])
    }

    func testGroupByDateOffIsOneRunOfNotesWithNoHeading() {
        let notes = [
            stamped("old", created: "2026-08-01T10:00:00+02:00"),
            stamped("today", created: "2026-09-15T08:00:00+02:00"),
        ]
        let groups = NotesFeed.groups(notes, grouped: false)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "")
        XCTAssertEqual(groups[0].notes.map(\.id), ["today", "old"])
    }

    func testPinnedNotesStayOnTopWhateverTheOrderAndGrouping() {
        let notes = [
            stamped("a", created: "2026-09-15T10:00:00+02:00", text: "zulo"),
            stamped("pinned", created: "2026-08-01T10:00:00+02:00", text: "aaa"),
        ]
        for grouped in [true, false] {
            for sort in NotesSort.allCases {
                let groups = NotesFeed.groups(
                    notes, pinned: ["pinned"], sort: sort, grouped: grouped
                )
                XCTAssertEqual(groups.first?.title, "Pinned", "\(sort) grouped=\(grouped)")
                XCTAssertEqual(groups.first?.notes.map(\.id), ["pinned"])
                // And only there: a pinned note is not repeated below.
                XCTAssertFalse(groups.dropFirst().flatMap(\.notes).contains { $0.id == "pinned" })
            }
        }
    }

    func testGroupingFollowsTheDateItIsSortedBy() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let now = NotesFeed.date("2026-09-15T12:00:00+02:00")!
        let note = stamped("edited-today", created: "2026-07-01T10:00:00+02:00",
                           edited: "2026-09-15T09:00:00+02:00")
        // Sorted by when it was edited, it belongs under Today, not under the
        // day it was written.
        XCTAssertEqual(
            NotesFeed.groups([note], sort: .dateEdited, now: now, calendar: calendar).map(\.title),
            ["Today"]
        )
        XCTAssertEqual(
            NotesFeed.groups([note], sort: .dateCreated, now: now, calendar: calendar).map(\.title),
            ["Earlier"]
        )
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
