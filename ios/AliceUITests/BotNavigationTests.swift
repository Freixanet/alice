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
}
