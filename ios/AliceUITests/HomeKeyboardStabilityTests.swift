import XCTest

@MainActor
final class HomeKeyboardStabilityTests: XCTestCase {
    func testEmptyHomeStaysPutForSoftwareKeyboard() {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["home.title"]
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
        XCTAssertLessThan(focused.maxY, keyboard.frame.minY, "Home title must remain above the keyboard")

        // Home sits in the middle of the room between the header and the
        // composer: the same air above the logo as under the last line.
        let headerBottom = app.buttons["chat.leading"].frame.maxY
        let composerTop = app.textFields.firstMatch.frame.minY
        let subtitle = app.staticTexts["You talk to Alice. One thing at a time."]
        XCTAssertTrue(subtitle.exists, "Home's subtitle should be on screen")
        let blockTop = app.images.firstMatch.exists
            ? min(app.images.firstMatch.frame.minY, focused.minY) : focused.minY
        let above = blockTop - headerBottom
        let below = composerTop - subtitle.frame.maxY
        print("HOME_CENTRED above=\(above) below=\(below) header=\(headerBottom) composerTop=\(composerTop)")
        // Air on both sides: clear of the composer's risen glass, and never
        // pushed up against the header. It rides a little above dead centre,
        // which is where the resting layout has always put it.
        XCTAssertGreaterThan(below, 0, "Home must not sit under the composer")
        XCTAssertGreaterThan(above, 0, "Home must not run under the header")
        XCTAssertLessThanOrEqual(
            deltaY, 2,
            "Home must never move down when the software keyboard appears"
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

        let title = app.staticTexts["home.title"]
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
