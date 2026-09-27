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
        XCTAssertFalse(app.buttons["home.menu.chats"].exists)

        let draft = "Keep this draft while switching"
        let field = app.descendants(matching: .any)["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(draft)
        chooseInterface("Experimental", in: app)
        XCTAssertTrue(app.buttons["home.menu.chats"].waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "experimental-home-light")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home.menu.chats"].waitForExistence(timeout: 20), "The interface choice must survive relaunch")
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        chooseInterface("Current", in: app)
        XCTAssertFalse(app.buttons["home.menu.chats"].exists)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "current-home-restored")
    }

    func testMenuRoutesKeepDraftAndStayAboveKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["home.menu.chats"].waitForExistence(timeout: 20))
        let field = app.descendants(matching: .any)["composer.text"]
        field.tap()
        field.typeText(" Menu route draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for name in ["chats", "agents", "notes", "agenda"] {
            let button = app.buttons["home.menu.\(name)"]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertLessThanOrEqual(button.frame.maxY, field.frame.minY)
        }
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-keyboard")

        for (name, backID) in [("agents", "bots.back"), ("notes", "notes.back"), ("agenda", "agenda.back")] {
            app.buttons["home.menu.\(name)"].tap()
            let back = app.buttons[backID]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
            XCTAssertTrue(back.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["home.menu.chats"].waitForExistence(timeout: 5))
            XCTAssertTrue((field.value as? String)?.contains("Menu route draft") == true)
        }
        app.buttons["home.menu.chats"].tap()
        XCTAssertTrue(app.buttons["sidebar.newChat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebar.newChat"].isHittable)
        app.buttons["sidebar.newChat"].tap()
        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.menu.chats"].isHittable)
        capture(app, "experimental-empty-home")
        field.tap()
        field.typeText("Empty home draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.menu.chats"].isHittable)
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-empty-home-keyboard")
    }

    func testDeveloperGateAndLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "NO", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["home.menu.chats"].exists, "Developer mode must gate the experiment")
        app.buttons["chat.leading"].tap()
        app.buttons["sidebar.settings"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Interface"].exists)
        app.terminate()

        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["home.menu.chats"].waitForExistence(timeout: 20))
        capture(app, "experimental-home-dark-large-text")
        app.descendants(matching: .any)["composer.text"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.menu.chats"].isHittable)
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-dark-large-keyboard")
        let scroll = app.scrollViews.containing(.button, identifier: "home.menu.chats").firstMatch
        XCTAssertTrue(scroll.exists)
        scroll.swipeLeft()
        XCTAssertTrue(app.buttons["home.menu.agenda"].isHittable)
        app.buttons["home.menu.agenda"].tap()
        XCTAssertTrue(app.buttons["agenda.back"].waitForExistence(timeout: 10))
        app.terminate()

        app.launchArguments = ["-seedLongBotChat", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["home.menu.chats"].exists, "Agent chats retain their existing composer")
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
