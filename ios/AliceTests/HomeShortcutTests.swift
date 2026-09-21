import XCTest
@testable import Alice

/// Pins on the empty home: saved on this phone, and opening one never reroutes
/// a missing chat onto another.
@MainActor
final class HomeShortcutTests: XCTestCase {
    private func store() throws -> (AppStore, String) {
        let suite = "alice.home-shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppStore(defaults: defaults), suite)
    }

    func testAPinRoundTripsThroughTheSavedJSON() throws {
        let pin = HomeShortcut(
            id: "pin-1",
            label: "Work",
            symbol: "folder",
            target: .noteFolder("work")
        )
        let data = try JSONEncoder().encode([pin])
        let loaded = try JSONDecoder().decode([HomeShortcut].self, from: data)
        XCTAssertEqual(loaded, [pin])
    }

    func testASavedPinSurvivesAMissingLabel() throws {
        let data = Data(#"[{"id":"p","target":{"kind":"note","value":"n1"}}]"#.utf8)
        let loaded = try JSONDecoder().decode([HomeShortcut].self, from: data)
        XCTAssertEqual(loaded.first?.id, "p")
        XCTAssertEqual(loaded.first?.label, "")
        XCTAssertEqual(loaded.first?.symbol, "square")
        XCTAssertEqual(loaded.first?.target, .note("n1"))
    }

    func testTheSamePlaceIsNotPinnedTwice() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let pin = HomeShortcut.place(.notes)
        store.addHomeShortcut(pin)
        store.addHomeShortcut(HomeShortcut.place(.notes))
        XCTAssertEqual(store.homeShortcuts.count, 1)
        XCTAssertTrue(store.hasHomeShortcut(matching: .place(.notes)))
    }

    func testPinsKeepTheOrderTheyWereMovedTo() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.addHomeShortcut(HomeShortcut(id: "a", label: "A", symbol: "a.circle", target: .note("a")))
        store.addHomeShortcut(HomeShortcut(id: "b", label: "B", symbol: "b.circle", target: .note("b")))
        store.addHomeShortcut(HomeShortcut(id: "c", label: "C", symbol: "c.circle", target: .note("c")))
        store.moveHomeShortcut("c", to: "a")
        XCTAssertEqual(store.homeShortcuts.map(\.id), ["c", "a", "b"])
    }

    func testANotePinOpensNotesOnThatNote() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.openHomeShortcut(HomeShortcut(
            label: "Call the bank", symbol: "note.text", target: .note("n1")
        ))
        XCTAssertTrue(store.showingNotes)
        XCTAssertFalse(store.showingBots)
        XCTAssertEqual(store.requestedNote, "n1")
    }

    func testAFolderPinOpensThatFolder() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.openHomeShortcut(HomeShortcut(
            label: "Work", symbol: "folder", target: .noteFolder("work")
        ))
        XCTAssertTrue(store.showingNotes)
        XCTAssertEqual(store.requestedNotesScope, .folder("work"))
    }

    func testAMacPinOpensTheLiveReading() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.openHomeShortcut(HomeShortcut(
            label: "Mac",
            symbol: LibraryTool.mac.symbol,
            target: .artifact(kind: LibraryTool.shortcutKind, value: LibraryTool.mac.rawValue)
        ))
        XCTAssertEqual(store.presentedLibraryTool, .mac)
        XCTAssertNil(store.requestedDestination)
        XCTAssertNil(store.requestedArtifact)
    }

    func testAPlacePinAsksTheDrawerForThatScreen() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.openHomeShortcut(HomeShortcut.place(.library))
        XCTAssertEqual(store.requestedDestination, .library)
        XCTAssertFalse(store.showingNotes)
    }

    func testAMissingChatIsLeftMissing() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let home = try XCTUnwrap(store.activeID)
        store.openHomeShortcut(HomeShortcut(
            label: "Gone", symbol: "bubble.left", target: .conversation("missing")
        ))
        XCTAssertEqual(store.activeID, home)
        XCTAssertFalse(store.showingBots)
        XCTAssertFalse(store.showingNotes)
    }

    func testAnUnknownAgentDoesNotOpenSomeoneElsesChat() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let home = Conversation(
            id: "home", title: "Home", createdAt: Date(), updatedAt: Date()
        )
        let other = Conversation(
            id: "radar", title: "Radar", createdAt: Date(), updatedAt: Date(),
            botName: "radar-ia"
        )
        store.conversations = [home, other]
        store.activeID = home.id
        store.openHomeShortcut(HomeShortcut(
            label: "Missing bot", symbol: "person", target: .bot("no-such-bot")
        ))
        XCTAssertEqual(store.activeID, home.id)
        XCTAssertEqual(store.conversations.map(\.id), ["home", "radar"])
    }

    func testANotePinShowsTheNotesCurrentTitle() {
        let pin = HomeShortcut(
            label: "Old title", symbol: "note.text", target: .note("n1")
        )
        let note = Note(id: "n1", createdAt: nil, text: "New title\nThe rest of the note")
        XCTAssertEqual(pin.displayedLabel(note: note), "New title")
        XCTAssertEqual(pin.displayedLabel(), "Old title")
    }

    func testAFolderPinShowsTheFoldersCurrentName() {
        let pin = HomeShortcut(label: "Work", symbol: "folder", target: .noteFolder("work"))
        XCTAssertEqual(pin.displayedLabel(folderName: "Projects"), "Projects")
        XCTAssertEqual(pin.displayedLabel(), "Work")
    }

    func testHomeReadsARenamedNoteFromTheStore() throws {
        let suite = "alice.home-shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let snap = NotesSnapshot(
            available: true, agent: "inbox",
            notes: [Note(id: "n1", createdAt: nil, text: "After the rename")]
        )
        defaults.set(try JSONEncoder().encode(snap), forKey: "alice.notes.snapshot")
        let store = AppStore(defaults: defaults)
        store.addHomeShortcut(HomeShortcut(
            label: "Before", symbol: "note.text", target: .note("n1")
        ))
        XCTAssertEqual(store.homeShortcutLabel(store.homeShortcuts[0]), "After the rename")
    }

    func testAChatPinKeepsTheInvokedAgentColour() throws {
        let (store, suite) = try store()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let chat = Conversation(
            id: "c1", title: "Descargas youtube.com",
            createdAt: Date(), updatedAt: Date(),
            messages: [
                Message(
                    id: "m1", role: .user, content: "@Descargas youtube.com",
                    createdAt: Date(), mentionProfile: "descargas"
                )
            ]
        )
        store.conversations = [chat]
        store.addHomeShortcut(HomeShortcut(
            label: "Old title", symbol: "bubble.left", target: .conversation("c1")
        ))
        let pin = store.homeShortcuts[0]
        XCTAssertEqual(store.homeShortcutLabel(pin), "Descargas youtube.com")
        XCTAssertEqual(
            store.homeShortcutStyledLabel(pin),
            store.titleStyled(for: chat)
        )
    }

    func testASavedPinIsThereAfterRelaunch() throws {
        let suite = "alice.home-shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = AppStore(defaults: defaults)
        first.addHomeShortcut(HomeShortcut.place(.routines))
        let second = AppStore(defaults: defaults)
        XCTAssertEqual(second.homeShortcuts.map(\.target), [.place(.routines)])
    }
}
