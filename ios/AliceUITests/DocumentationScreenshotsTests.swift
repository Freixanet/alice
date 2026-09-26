import XCTest

/// Reproducible repository images from a fresh, isolated simulator.
@MainActor
final class DocumentationScreenshotsTests: XCTestCase {
    func testCaptureChatWithLargeTextAndDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-seedLongBotChat", "-alice.theme", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["composer.action"].waitForExistence(timeout: 10))
        capture(app, name: "alice-ios-chat-dark-accessibility")
    }

    func testCaptureMobileEntryPoints() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        capture(app, name: "alice-ios-chat")
        let connect = app.buttons["home.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.navigationBars["Connect"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Scan pairing QR"].exists)
        app.navigationBars["Connect"].buttons["Back"].tap()
        app.buttons["chat.leading"].tap()
        XCTAssertTrue(app.buttons["sidebar.row.Agents"].waitForExistence(timeout: 10))
        capture(app, name: "alice-ios-navigation")
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        capture(app, name: "alice-ios-settings")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
