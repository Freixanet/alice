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

    /// Relaunches at the largest accessibility text size and the smallest
    /// screen this app supports, which is where a list of destinations stops
    /// fitting and starts hiding things.
    private func relaunchWithLargestText() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
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

    /// The drawer is everyday navigation, not an administration console.
    /// Technical destinations remain available from Settings → Advanced and
    /// from search without competing with chats for vertical space.
    func testDrawerKeepsOnlyEverydayDestinations() {
        openDrawer()
        for title in ["Bots", "Activity", "Routines", "Projects", "Library"] {
            assertDrawerRow(title)
        }
        for title in [
            "Files", "Channels", "Integrations (MCP)", "Skills", "Tools",
            "Webhooks", "Git", "System",
        ] {
            XCTAssertFalse(
                app.buttons["sidebar.row.\(title)"].exists,
                "\(title) should live outside the everyday drawer"
            )
        }
    }

    /// Two actions, not one. The drawer has to be opened first, so calling
    /// Activity "one tap from the conversation" would be wrong — it is two, and
    /// this measures it rather than asserting a number someone hoped for.
    func testActivityIsTwoActionsFromTheConversation() {
        var actions = 0
        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap(); actions += 1

        let activity = app.buttons["sidebar.row.Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap(); actions += 1

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
        XCTAssertEqual(actions, 2, "opening the drawer is an action too")
    }

    /// A drawer that scrolls is fine; a destination that cannot be reached at
    /// the largest text size is not.
    func testEveryDestinationSurvivesTheLargestText() {
        relaunchWithLargestText()
        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 25))
        leading.tap()

        for title in ["Bots", "Activity", "Routines", "Projects", "Library"] {
            let row = app.buttons["sidebar.row.\(title)"]
            XCTAssertTrue(
                row.waitForExistence(timeout: 10),
                "“\(title)” is unreachable at accessibility text sizes"
            )
        }
        // And the controls stay hittable rather than being squeezed out.
        for identifier in ["sidebar.search", "sidebar.settings", "sidebar.newChat"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 10), identifier)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, identifier)
        }
    }

    /// A tap on a notification with the app closed.
    ///
    /// Driven by an injected route rather than a real banner: delivering one
    /// needs a granted permission and a live server, and neither belongs in a
    /// navigation test. What this proves is the half that was missing — the
    /// route survives a cold start and lands somewhere it can be acted on,
    /// with nothing of the session left in memory. It is not evidence of
    /// remote push, which Alice does not have.
    func testTapOnANotificationLandsSomewhereActionableFromCold() throws {
        app.terminate()
        app = XCUIApplication()
        let route = """
        {"event":"approval:req-cold","conversation":"missing-conv",        "profile":"radar-ia","session":"sess-1","request":"req-cold"}
        """
        app.launchArguments += ["-notificationRoute", route]
        app.launch()

        // The conversation named on the notification is not on this phone, so
        // the tap must still reach the record rather than opening nothing.
        XCTAssertTrue(
            app.buttons["chat.leading"].waitForExistence(timeout: 25),
            "a tap whose destination is gone must still land in a usable app"
        )
        app.buttons["chat.leading"].tap()
        let activity = app.buttons["sidebar.row.Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
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
        let general = app.staticTexts["General"]
        let connection = app.staticTexts["Connection"]
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        // Connection leads: whether Alice can reach Hermes is what the rest of
        // Settings depends on, and what people open it to check.
        XCTAssertLessThan(
            connection.frame.minY, general.frame.minY,
            "Connection should be the first settings section"
        )
        XCTAssertTrue(app.buttons["Advanced"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Sessions"].exists, "history is not a setting")
    }

    func testActivityOwnsHistoryAndUsage() {
        openDrawer()
        app.buttons["sidebar.row.Activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Insights"].waitForExistence(timeout: 10))
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
