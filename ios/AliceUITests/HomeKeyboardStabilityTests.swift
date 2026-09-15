import XCTest

@MainActor
final class HomeKeyboardStabilityTests: XCTestCase {
    func testEmptyHomeStaysPutForSoftwareKeyboard() {
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
        // Home rides up with the composer and never drops: sliding down is how
        // it used to end up behind the composer's glass.
        XCTAssertLessThanOrEqual(
            deltaY, 2,
            "Empty Home must never move down when the software keyboard appears"
        )
        XCTAssertGreaterThan(focused.minY, 0, "Home title must stay on screen")
        XCTAssertLessThan(focused.maxY, keyboard.frame.minY, "Home title must remain above the keyboard")

        // Everything Home says has to stay clear of the composer, not just the
        // title: the line under it was ending up behind the glass.
        let composerTop = app.textFields.firstMatch.frame.minY
        let subtitle = app.staticTexts["You talk to Alice. One thing at a time."]
        XCTAssertTrue(subtitle.exists, "Home's subtitle should be on screen")
        print("HOME_CLEARANCE subtitle=\(subtitle.frame) composerTop=\(composerTop)")
        XCTAssertLessThan(
            subtitle.frame.maxY, composerTop,
            "Home's subtitle must not sit under the composer once the keyboard opens"
        )
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
