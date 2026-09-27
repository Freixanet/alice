import XCTest

@MainActor
final class ExperimentalHomeMenuTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    func testAvatarSwitchPreservesDraftAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES"]
        app.launch()
        chooseInterface("Current", in: app)
        XCTAssertFalse(app.buttons["home.menu.chat"].exists)

        let draft = "Keep this draft while switching"
        let field = app.descendants(matching: .any)["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(draft)
        chooseInterface("Experimental", in: app)
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "experimental-home-light")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 20), "The interface choice must survive relaunch")
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        chooseInterface("Current", in: app)
        XCTAssertFalse(app.buttons["home.menu.chat"].exists)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "current-home-restored")
    }

    func testMenuRoutesKeepDraftAndStayAboveKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 20))
        let field = app.descendants(matching: .any)["composer.text"]
        field.tap()
        field.typeText(" Menu route draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for name in ["chat", "today", "goals", "feed", "library"] {
            let button = app.buttons["home.menu.\(name)"]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minY, field.frame.maxY)
        }
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-keyboard")

        app.buttons["home.menu.chat"].tap()
        XCTAssertTrue(app.buttons["Today options"].waitForExistence(timeout: 10))
        app.buttons["chat.leading"].tap()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 5))

        app.buttons["home.menu.today"].tap()
        XCTAssertTrue(app.buttons["Today options"].waitForExistence(timeout: 10))
        app.buttons["chat.leading"].tap()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 5))

        app.buttons["home.menu.goals"].tap()
        XCTAssertTrue(app.buttons["goals.back"].waitForExistence(timeout: 10))
        app.buttons["goals.back"].tap()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 5))

        app.buttons["home.menu.feed"].tap()
        XCTAssertTrue(app.navigationBars["Feed"].waitForExistence(timeout: 10))
        capture(app, "experimental-feed")
        app.navigationBars["Feed"].buttons["Back"].tap()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 5))

        app.buttons["home.menu.library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        app.navigationBars["Library"].buttons["Back"].tap()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String)?.contains("Menu route draft") == true)

        app.buttons["chat.leading"].tap()
        XCTAssertTrue(app.buttons["sidebar.newChat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebar.newChat"].isHittable)
        app.buttons["sidebar.newChat"].tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.menu.chat"].isHittable)
        capture(app, "experimental-empty-home")
        field.tap()
        field.typeText("Empty home draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.menu.chat"].isHittable)
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-empty-home-keyboard")
    }

    func testDeveloperGateAndLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "NO", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["home.menu.chat"].exists, "Developer mode must gate the experiment")
        app.buttons["chat.leading"].tap()
        app.buttons["sidebar.settings"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Interface"].exists)
        app.terminate()

        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["home.menu.chat"].waitForExistence(timeout: 20))
        capture(app, "experimental-home-dark-large-text")
        app.descendants(matching: .any)["composer.text"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.menu.chat"].isHittable)
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-dark-large-keyboard")
        for name in ["chat", "today", "goals", "feed", "library"] {
            XCTAssertTrue(app.buttons["home.menu.\(name)"].isHittable)
        }
        app.buttons["home.menu.feed"].tap()
        XCTAssertTrue(app.navigationBars["Feed"].waitForExistence(timeout: 10))
        app.terminate()

        app.launchArguments = ["-seedLongBotChat", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["home.menu.chat"].exists, "Agent chats retain their existing composer")
    }

    private func chooseInterface(_ name: String, in app: XCUIApplication) {
        let leading = app.buttons["chat.leading"]
        XCTAssertTrue(leading.waitForExistence(timeout: 20))
        leading.tap()
        let avatar = app.buttons["sidebar.settings"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        avatar.press(forDuration: 1)
        let menu = app.buttons["Interface"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let choice = app.buttons[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
