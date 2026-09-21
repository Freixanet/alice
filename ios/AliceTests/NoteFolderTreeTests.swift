import XCTest
@testable import Alice

/// Folders inside folders — an arrangement of the folders page, since the store
/// an agent keeps has no nesting of its own.
final class NoteFolderTreeTests: XCTestCase {
    private let folders = [
        NoteFolder(id: "work", name: "Work"),
        NoteFolder(id: "notes", name: "Meeting notes"),
        NoteFolder(id: "deep", name: "Minutes"),
        NoteFolder(id: "home", name: "Home"),
    ]
    /// Work › Meeting notes › Minutes, and Home on its own.
    private let nested = ["notes": "work", "deep": "notes"]

    func testOnlyFoldersWithNoParentAreAtTheTop() {
        let roots = NoteFolderTree.roots(folders, parent: nested)
        XCTAssertEqual(roots.map(\.id), ["work", "home"])
    }

    func testAFolderWhoseParentIsGoneComesBackToTheTop() {
        // "Work" deleted: what was inside it must not disappear with it.
        let left = folders.filter { $0.id != "work" }
        let roots = NoteFolderTree.roots(left, parent: nested)
        XCTAssertEqual(roots.map(\.id), ["notes", "home"])
    }

    func testChildrenAreTheFoldersDirectlyInside() {
        XCTAssertEqual(
            NoteFolderTree.children(of: "work", in: folders, parent: nested).map(\.id), ["notes"]
        )
        XCTAssertEqual(
            NoteFolderTree.children(of: "notes", in: folders, parent: nested).map(\.id), ["deep"]
        )
        XCTAssertTrue(NoteFolderTree.children(of: "home", in: folders, parent: nested).isEmpty)
    }

    func testBeingInsideCountsEveryStepUp() {
        XCTAssertTrue(NoteFolderTree.isInside("deep", "work", parent: nested))
        XCTAssertTrue(NoteFolderTree.isInside("notes", "work", parent: nested))
        XCTAssertFalse(NoteFolderTree.isInside("work", "deep", parent: nested))
        XCTAssertFalse(NoteFolderTree.isInside("home", "work", parent: nested))
    }

    func testALoopInTheMapIsNotAnInfiniteWalk() {
        let looped = ["a": "b", "b": "a"]
        XCTAssertFalse(NoteFolderTree.isInside("a", "c", parent: looped))
    }

    func testAFolderCanBeMovedIntoAnother() {
        let moved = NoteFolderTree.moving("home", into: "work", parent: nested)
        XCTAssertEqual(moved["home"], "work")
    }

    func testAFolderCannotBeMovedIntoItself() {
        XCTAssertEqual(NoteFolderTree.moving("work", into: "work", parent: nested), nested)
    }

    func testAFolderCannotBeMovedInsideItsOwnSubfolder() {
        // Work into Minutes would take Work, Meeting notes and Minutes off the
        // page together, with nothing left to open.
        XCTAssertEqual(NoteFolderTree.moving("work", into: "deep", parent: nested), nested)
    }

    func testMovingToTheTopLevelForgetsTheParent() {
        let moved = NoteFolderTree.moving("notes", into: nil, parent: nested)
        XCTAssertNil(moved["notes"])
        XCTAssertEqual(moved["deep"], "notes")
    }

    func testDeletingAFolderFreesWhatWasInsideIt() {
        let after = NoteFolderTree.removing("work", from: nested)
        XCTAssertNil(after["notes"])
        XCTAssertEqual(after["deep"], "notes")
    }

    func testUnknownIdsInTheSavedOrderAreSkipped() {
        let shown = NoteFolderTree.ordered(
            folders, pinned: [], order: ["gone", "home", "work", "also-gone"]
        )
        XCTAssertEqual(shown.map(\.id), ["home", "work", "notes", "deep"])
    }

    func testPinnedFoldersFloatFirstThenTheSavedOrder() {
        let shown = NoteFolderTree.ordered(
            folders, pinned: ["deep", "home"], order: ["notes", "home", "work"]
        )
        XCTAssertEqual(shown.map(\.id), ["home", "deep", "notes", "work"])
    }

    func testNameSortStillFloatsPinsThenSortsTheRest() {
        let shown = NoteFolderTree.ordered(
            folders, pinned: ["deep"], order: ["work"], sort: .name
        )
        XCTAssertEqual(shown.map(\.id), ["deep", "home", "notes", "work"])
    }

    func testPlacingAFolderBeforeAnotherRewritesOnlyThatGroup() {
        let order = NoteFolderTree.placing(
            "home", beside: "work", after: false,
            displayed: ["work", "home"], order: ["notes", "work", "deep", "home"]
        )
        XCTAssertEqual(order, ["notes", "home", "work", "deep"])
    }

    func testMovingDownSwapsWithTheNextSibling() {
        let order = NoteFolderTree.movingInList(
            "work", up: false, displayed: ["work", "home"], order: ["work", "home"]
        )
        XCTAssertEqual(order, ["home", "work"])
    }

    func testMovingPastTheEndLeavesTheOrderAlone() {
        XCTAssertEqual(
            NoteFolderTree.movingInList(
                "home", up: false, displayed: ["work", "home"], order: ["work", "home"]
            ),
            ["work", "home"]
        )
    }
}
