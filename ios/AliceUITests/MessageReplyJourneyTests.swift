import XCTest

@MainActor
final class MessageReplyJourneyTests: XCTestCase {
    func testSwipeOpensKeyboardAndCancelKeepsTypedReply() {
        let app = XCUIApplication()
        app.launchArguments = ["-messageReplyReview", "-alice.developerMode", "NO", "-alice.developer.homeInterface", "current"]
        app.launch()
        let message = app.descendants(matching: .any)["message.reply-fixture"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 25))
        message.swipeRight()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let cancel = app.buttons["composer.cancelReply"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeText("A please")
        cancel.tap()
        XCTAssertFalse(cancel.exists)
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "A please")).firstMatch.exists)
        XCTAssertFalse(app.buttons["sidebar.row.Library"].isHittable, "Replying must not open the drawer")
    }

    func testLibrarySelectorIsTallerAndNotesIsOnlyInLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-alice.developerMode", "NO", "-alice.developer.homeInterface", "current"]
        app.launch()
        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
        XCTAssertFalse(app.buttons["sidebar.row.Notes"].exists)
        app.buttons["sidebar.row.Library"].tap()
        let selector = app.segmentedControls["library.part"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(selector.frame.height, 44)
        XCTAssertEqual(selector.buttons.count, 3)
        selector.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(selector.buttons.element(boundBy: 2).isSelected)
    }
}
