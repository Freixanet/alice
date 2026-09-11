import XCTest

@MainActor
final class HomeKeyboardStabilityTests: XCTestCase {
    func testEmptyHomeMovesUpForSoftwareKeyboard() {
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
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let focused = title.frame

        let deltaY = focused.minY - before.minY
        print("HOME_FRAME before=\(before) focused=\(focused) deltaY=\(deltaY)")
        XCTAssertLessThan(deltaY, -20, "Empty Home should rise when the software keyboard appears")
        XCTAssertLessThan(focused.maxY, keyboard.frame.minY, "Home title must remain above the keyboard")
    }

    /// A press on the composer's own button must not put the keyboard away.
    ///
    /// The tap-to-dismiss gesture covered the whole screen, composer included,
    /// so Send closed the keyboard — sliding the button out from under the
    /// finger — instead of sending, and it took several presses. Pressed here
    /// with nothing typed, so the test sends nothing anywhere.
    func testPressingTheComposerButtonKeepsTheKeyboard() {
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

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))

        let action = app.buttons["composer.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(keyboard.exists, "a press on the composer closed the keyboard")

        // A tap away from the composer still puts the keyboard away.
        title.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
    }
}
