import XCTest

/// "Turn off WhatsApp" showed its confirmation, the red button was pressed, and
/// nothing happened: no request reached Hermes and no message appeared under
/// the alert. Whatever a confirmed fix does, it has to leave a trace — here,
/// unconnected, the failure note.
@MainActor
final class ActivityFixConfirmationTests: XCTestCase {

    func testAConfirmedFixDoesSomething() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedChannelAlert"]
        app.launch()

        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
        let activity = app.buttons["sidebar.row.Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()

        let fix = app.buttons["activity.fix.0.attention:channel:whatsapp"]
        XCTAssertTrue(fix.waitForExistence(timeout: 15), "the seeded WhatsApp alert should offer its fix")
        fix.tap()

        // The confirmation's own button, not the row's button of the same name.
        let confirm = app.sheets.buttons["Turn off WhatsApp"].firstMatch.exists
            ? app.sheets.buttons["Turn off WhatsApp"].firstMatch
            : app.buttons.matching(NSPredicate(format: "label == %@", "Turn off WhatsApp"))
                .allElementsBoundByIndex.last!
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the confirmation should appear")
        confirm.tap()

        let outcome = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "didn't work")).firstMatch
        XCTAssertTrue(
            outcome.waitForExistence(timeout: 20),
            "confirming the fix must run it and show what happened"
        )
    }
}
