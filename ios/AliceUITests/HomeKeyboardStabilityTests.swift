import XCTest

@MainActor
final class HomeKeyboardStabilityTests: XCTestCase {
    func testEmptyHomeDoesNotMoveWhenKeyboardAppears() {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["What are we working on?"]
        if !title.waitForExistence(timeout: 8) {
            let leading = app.buttons["chat.leading"]
            XCTAssertTrue(leading.waitForExistence(timeout: 10))
            leading.tap()
            let newChat = app.buttons["sidebar.newChat"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 10))
            newChat.tap()
        }

        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let before = title.frame

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let focused = title.frame

        let focusedDelta = abs(focused.minY - before.minY)
        print("HOME_FRAME before=\(before) focused=\(focused) deltaY=\(focusedDelta)")
        XCTAssertLessThanOrEqual(focusedDelta, 0.5, "Empty-home title moved when keyboard appeared")

    }
}
