import XCTest

/// The experimental home: the composer alone, full width and centred. The round section button
/// that sat at its left was removed; Notes and Library are in the drawer, Routines in Settings.
@MainActor
final class ExperimentalHomeMenuTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    func testComposerIsAloneCentredAndKeepsItsDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "light"]
        app.launch()
        let capsule = app.descendants(matching: .any)["composer.capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["home.experimentalMenu"].exists, "The section button beside the composer is gone")
        assertCentredAndWide(capsule, in: app)

        let field = app.descendants(matching: .any)["composer.text"]
        field.tap()
        field.typeText("Keep this draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        assertCentredAndWide(capsule, in: app)
        capture(app, "experimental-home-keyboard")

        app.terminate()
        app.launch()
        XCTAssertTrue(capsule.waitForExistence(timeout: 20))
        XCTAssertTrue((field.value as? String)?.contains("Keep this draft") == true)
    }

    func testLargeTextKeepsTheComposerReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let capsule = app.descendants(matching: .any)["composer.capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 20))
        app.descendants(matching: .any)["composer.text"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-dark-large-keyboard")
    }

    private func assertCentredAndWide(_ capsule: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(capsule.frame.midX, window.midX, accuracy: 2, "centred", file: file, line: line)
        XCTAssertGreaterThanOrEqual(capsule.frame.width, window.width - 48, "full width", file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
