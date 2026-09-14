import XCTest

/// The two controls that looked right on a phone and did nothing.
@MainActor
final class BotNavigationTests: XCTestCase {
    /// Jump to latest has to reach the end of a long bot chat, the one kind
    /// of conversation long enough to need it.
    func testJumpToLatestReachesTheEndOfALongBotChat() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedLongBotChat"]
        app.launch()

        let last = app.staticTexts["Respuesta de prueba 30."]
        XCTAssertTrue(last.waitForExistence(timeout: 15), "the seeded chat opens at its end")

        let jump = app.buttons["chat.scrollToBottom"]
        for _ in 0..<6 where !jump.exists {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "scrolled away, the jump control appears")

        jump.tap()
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let reached = NSPredicate(format: "isHittable == true")
        expectation(for: reached, evaluatedWith: last)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(
            jump.waitForExistence(timeout: 1) && jump.isHittable,
            "at the end, the jump control goes away"
        )
    }

    /// A chat whose replies are as long as a Radar IA report must open showing
    /// its latest message, not a blank page that fills in once scrolled.
    func testATallBotChatOpensShowingItsLatestMessage() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedTallBotChat"]
        app.launch()

        let latest = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Respuesta de prueba 30.")
        ).firstMatch
        XCTAssertTrue(
            latest.waitForExistence(timeout: 10),
            "the latest reply is drawn on open, without scrolling"
        )
        // A report is taller than the screen, so at the end of the chat only its
        // last lines show: on screen means overlapping the window, not having
        // its centre visible.
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(latest.frame.intersects(window), "and it is on screen")
        XCTAssertGreaterThan(latest.frame.maxY, window.midY, "at the end of the chat")
    }

    /// A reply that lands whole — a bot's report arrives in one piece once its
    /// turn ends — must not be left underneath the composer for the reader to
    /// scroll out.
    func testAReplyThatGrowsIsNotLeftUnderTheComposer() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedLongBotChat", "-growSeededChat"]
        app.launch()

        let grown = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Fin del informe")
        ).firstMatch
        XCTAssertTrue(grown.waitForExistence(timeout: 15), "the last reply grows")
        let composer = app.buttons["composer.action"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        for _ in 0..<10 where grown.frame.maxY > composer.frame.minY {
            usleep(300_000)
        }
        XCTAssertLessThanOrEqual(
            grown.frame.maxY, composer.frame.minY,
            "the end of the reply sits above the composer without scrolling"
        )
        XCTAssertFalse(
            app.buttons["chat.scrollToBottom"].exists,
            "following the chat, there is nothing to jump to"
        )
    }

    /// Pressed straight after a flick, while the transcript is still coasting,
    /// which is when a thumb reaches for it.
    func testJumpToLatestWorksWhileTheChatIsStillMoving() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedLongBotChat"]
        app.launch()

        let last = app.staticTexts["Respuesta de prueba 30."]
        XCTAssertTrue(last.waitForExistence(timeout: 15))
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)

        let jump = app.buttons["chat.scrollToBottom"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        jump.tap()

        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: last)
        waitForExpectations(timeout: 5)
    }

    /// A thumb is never perfectly still. A press on Back that drifts a few
    /// points sideways must still go back, rather than being taken for the
    /// start of a swipe by the screen-wide pan.
    func testBotsBackSurvivesAThumbThatDrifts() {
        let app = XCUIApplication()
        app.launch()

        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
        let bots = app.buttons["sidebar.row.Bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 10))
        bots.tap()

        let back = app.buttons["bots.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        let start = back.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 9, dy: 1))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 300, thenHoldForDuration: 0)

        XCTAssertTrue(
            back.waitForNonExistence(timeout: 5),
            "a slightly wobbly press on Back still leaves the Bots page"
        )
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 5))
    }

    /// Backing out of a bot is a two-step journey: bot chat → Bots → Home.
    /// The second step must change the active conversation before uncovering
    /// Chat; otherwise the Bots page disappears onto the same bot again.
    func testBackFromABotThroughBotsReturnsHome() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedLongBotChat"]
        app.launch()

        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        XCTAssertEqual(leading.label, "Agents")
        leading.tap()

        let back = app.buttons["bots.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()

        XCTAssertTrue(leading.waitForExistence(timeout: 10))
        XCTAssertEqual(leading.label, "Chats", "Bots Back must uncover Alice, not the bot")
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
    }

    func testSwipeBackFromBotsAfterABotReturnsHome() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedLongBotChat"]
        app.launch()

        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
        XCTAssertTrue(app.buttons["bots.back"].waitForExistence(timeout: 10))

        app.swipeRight(velocity: .fast)

        XCTAssertTrue(leading.waitForExistence(timeout: 10))
        XCTAssertEqual(leading.label, "Chats", "the Bots swipe must uncover Alice")
        XCTAssertTrue(app.buttons["bots.back"].waitForNonExistence(timeout: 5))
    }

    /// A bot row covers most of this page, so the page-wide back gesture must
    /// win once a press becomes a horizontal swipe. The row must remain a
    /// normal button when the finger does not travel.
    func testSwipeBackStartingOnABotRowReturnsHomeInsteadOfOpeningTheBot() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedLongBotChat"]
        app.launch()

        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
        XCTAssertTrue(app.buttons["bots.back"].waitForExistence(timeout: 10))

        let row = firstVisibleBotRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Bots page exposes a bot row")
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 280, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 900, thenHoldForDuration: 0)

        XCTAssertTrue(app.buttons["bots.back"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(leading.waitForExistence(timeout: 5))
        XCTAssertEqual(leading.label, "Chats", "swiping across a row must return to Home")
    }

    func testBotRowStillOpensWhenTappedWithoutDragging() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedLongBotChat"]
        app.launch()

        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
        XCTAssertTrue(app.buttons["bots.back"].waitForExistence(timeout: 10))

        let row = firstVisibleBotRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertTrue(app.buttons["bots.back"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(leading.waitForExistence(timeout: 5))
        XCTAssertEqual(leading.label, "Agents", "a stationary tap must still open the bot")
    }

    private func firstVisibleBotRow(in app: XCUIApplication) -> XCUIElement {
        let collapsedUnassigned = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Unassigned,")
        ).firstMatch
        if collapsedUnassigned.waitForExistence(timeout: 3) {
            collapsedUnassigned.tap()
        }
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bots.row.")
        ).firstMatch
    }
}
