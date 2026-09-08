import XCTest

/// The journeys a person actually takes, driven through the real app.
///
/// The unit suite covers contracts — what a payload means, which route a write
/// goes to. None of it can tell you whether a destination is still reachable
/// after the drawer was rearranged, which is exactly the risk in changing
/// navigation. These check behaviour, not layout: a row is found by an
/// identifier tied to its destination, so the wording stays free to change.
@MainActor
final class NavigationJourneyTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Chat is the app. It has to be what you land on, with no dashboard to
    /// cross first — a person opening Alice to say something should be able to.
    func testLaunchLandsInChat() {
        XCTAssertTrue(
            app.buttons["chat.leading"].waitForExistence(timeout: 20),
            "the conversation should be the first thing on screen"
        )
    }

    private func openDrawer() {
        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
    }

    private func assertDrawerRow(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["sidebar.row.\(title)"]
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "“\(title)” is no longer reachable from the drawer",
            file: file, line: line
        )
    }

    /// Grouping the drawer must not have cost a destination. Every one of them
    /// is still one tap from the conversation.
    func testEveryDrawerDestinationSurvivedGrouping() {
        openDrawer()
        for title in [
            "Bots", "Activity", "Routines", "Projects", "Files", "Library",
            "Channels", "Integrations (MCP)", "Skills", "Tools", "Webhooks",
            "Git", "System",
        ] {
            assertDrawerRow(title)
        }
    }

    func testActivityOpensFromTheDrawer() {
        openDrawer()
        app.buttons["sidebar.row.Activity"].tap()
        XCTAssertTrue(
            app.otherElements["activity.list"].waitForExistence(timeout: 10)
                || app.collectionViews["activity.list"].waitForExistence(timeout: 5)
                || app.tables["activity.list"].waitForExistence(timeout: 5),
            "Activity should open"
        )
    }

    func testSettingsOpensFromTheDrawer() {
        openDrawer()
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 20),
            "Settings should open"
        )
        // The three rows that used to be duplicated here are gone; they are one
        // tap away in the drawer instead. Settings keeps what it is for.
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 10))
    }

    /// Apple's minimum target is 44 x 44. These three are glyphs inside glass
    /// discs, and a `.frame(44, 44)` on the glyph sizes the layout without
    /// moving the button's hit region or its accessibility frame off the
    /// symbol — Settings measured 11.7 x 20.3, New chat 18 x 18, Search
    /// 20 x 20. A control that small is hard to hit deliberately and, for
    /// anyone relying on assistive technology, hard to hit at all.
    func testDrawerControlsMeetTheMinimumTargetSize() {
        openDrawer()
        for identifier in ["sidebar.search", "sidebar.settings", "sidebar.newChat"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 10), identifier)
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(
                frame.width, 44, "\(identifier) is \(frame.width)pt wide"
            )
            XCTAssertGreaterThanOrEqual(
                frame.height, 44, "\(identifier) is \(frame.height)pt tall"
            )
        }
    }

    /// The point of the searchable destination list: a word a person would
    /// actually type reaches a screen named after something else entirely.
    func testSearchFindsAScreenByAHumanWord() {
        openDrawer()
        let search = app.buttons["sidebar.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("telegram")

        // "telegram" appears nowhere in the word "Channels".
        XCTAssertTrue(
            app.buttons["search.place.channels"].waitForExistence(timeout: 10),
            "searching a human word should offer the screen that holds it"
        )
    }

    func testSearchFindsAScreenByItsHermesName() {
        openDrawer()
        app.buttons["sidebar.search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("cron")

        XCTAssertTrue(
            app.buttons["search.place.routines"].waitForExistence(timeout: 10),
            "an expert's vocabulary should reach the same screen"
        )
    }
}
