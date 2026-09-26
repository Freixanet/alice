import XCTest

@MainActor
final class EverydayVisualReviewTests: XCTestCase {
    func testEverydayScreensInLightMode() { review(theme: "light", large: false) }
    func testEverydayScreensInDarkModeWithLargeText() { review(theme: "dark", large: true) }

    private func review(theme: String, large: Bool) {
        let app = XCUIApplication()
        app.launchArguments += ["-visualReview", "-alice.theme", theme]
        if large {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        capture(app, "populated-chat-\(theme)")
        app.buttons["chat.leading"].tap()
        XCTAssertTrue(app.buttons["sidebar.row.Agents"].waitForExistence(timeout: 10))
        capture(app, "recents-\(theme)")
        app.buttons["sidebar.row.Agents"].tap()
        XCTAssertTrue(app.buttons["bots.back"].waitForExistence(timeout: 10))
        capture(app, "agents-\(theme)")
        app.buttons["bots.back"].tap()
        app.buttons["chat.leading"].tap()
        app.buttons["sidebar.row.Notes"].tap()
        XCTAssertTrue(app.buttons["notes.back"].waitForExistence(timeout: 10))
        capture(app, "notes-\(theme)")
        app.buttons["notes.back"].tap()
        app.buttons["chat.leading"].tap()
        app.buttons["sidebar.row.Agenda"].tap()
        XCTAssertTrue(app.buttons["agenda.back"].waitForExistence(timeout: 10))
        capture(app, "agenda-unconnected-\(theme)")
        app.buttons["agenda.back"].tap()
        app.buttons["chat.leading"].tap()
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        capture(app, "settings-\(theme)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "alice-review-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
