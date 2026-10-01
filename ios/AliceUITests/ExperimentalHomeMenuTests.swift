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
        XCTAssertFalse(menuButton(in: app).exists)

        chooseInterface("Experimental", in: app)
        // «Today options» left the experimental home; its section button is what it shows now.
        XCTAssertTrue(menuButton(in: app).waitForExistence(timeout: 10))
        let draft = "Keep this draft while switching"
        let field = app.descendants(matching: .any)["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(draft)
        XCTAssertTrue(menuButton(in: app).exists)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "experimental-today-keyboard")

        app.terminate()
        app.launch()
        XCTAssertTrue(menuButton(in: app).waitForExistence(timeout: 20), "The interface choice must survive relaunch")
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        chooseInterface("Current", in: app)
        XCTAssertFalse(menuButton(in: app).exists)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "current-home-restored")
    }

    /// The round button and the composer sit in one row at the button's own
    /// height, and both stay put — and hittable — once the keyboard is up.
    func testMenuRoutesKeepDraftAndStayWithKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "light"]
        app.launch()
        let button = menuButton(in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        XCTAssertEqual(button.frame.width, button.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        let field = app.descendants(matching: .any)["composer.text"]
        // Bottom-aligned with the composer's capsule, not with the text field inside it.
        let capsule = app.descendants(matching: .any)["composer.capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
        XCTAssertEqual(button.frame.maxY, capsule.frame.maxY, accuracy: 2)

        field.tap()
        field.typeText(" Menu route draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(button.exists)
        XCTAssertTrue(button.isHittable)
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-keyboard")

        app.terminate()
        app.launch()
        XCTAssertTrue(menuButton(in: app).waitForExistence(timeout: 20))
        XCTAssertTrue((field.value as? String)?.contains("Menu route draft") == true)

        XCTAssertTrue(app.buttons["Today options"].waitForExistence(timeout: 10))
        for name in ["Today", "Goals", "Feed", "Library", "Chat"] {
            selectSection(name, in: app)
            switch name {
            case "Goals": XCTAssertTrue(app.buttons["goals.add"].waitForExistence(timeout: 5))
            case "Feed": XCTAssertTrue(app.navigationBars["Feed"].waitForExistence(timeout: 5))
            case "Library": XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
            default: XCTAssertTrue(app.buttons["Today options"].waitForExistence(timeout: 5))
            }
            capture(app, "experimental-section-\(name.lowercased())")
        }
        XCTAssertTrue((field.value as? String)?.contains("Menu route draft") == true)
    }

    func testDeveloperGateAndLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "NO", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(menuButton(in: app).exists, "Developer mode must gate the experiment")
        app.buttons["chat.leading"].tap()
        app.buttons["sidebar.settings"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Interface"].exists)
        app.terminate()

        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(menuButton(in: app).waitForExistence(timeout: 20))
        capture(app, "experimental-home-dark-large-text")
        app.descendants(matching: .any)["composer.text"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(menuButton(in: app).isHittable)
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-dark-large-keyboard")
        app.terminate()
        app.launch()
        XCTAssertTrue(menuButton(in: app).waitForExistence(timeout: 20))
        // The feed left the menu for a swipe from the chat (f0a915b); a section still in it opens.
        selectSection("Notes", in: app)
        XCTAssertTrue(app.navigationBars["Folders"].waitForExistence(timeout: 10))
        app.terminate()

        app.launchArguments = ["-seedLongBotChat", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(menuButton(in: app).exists, "Agent chats retain their existing composer")
    }

    /// The round button itself, wherever it sits — beside the composer or
    /// alone above a destination page.
    private func menuButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["home.experimentalMenu"]
    }

    /// Opens the button's menu and taps a section by its title.
    private func selectSection(_ name: String, in app: XCUIApplication) {
        let button = menuButton(in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let item = app.buttons[name]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
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
