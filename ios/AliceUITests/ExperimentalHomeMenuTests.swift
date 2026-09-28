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
        XCTAssertFalse(menuButton("chat", in: app).exists)

        chooseInterface("Experimental", in: app)
        XCTAssertTrue(app.buttons["Today options"].waitForExistence(timeout: 10))
        let draft = "Keep this draft while switching"
        let field = app.descendants(matching: .any)["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(draft)
        XCTAssertFalse(menuButton("chat", in: app).exists)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "experimental-today-keyboard")

        app.terminate()
        app.launch()
        XCTAssertTrue(menuButton("chat", in: app).waitForExistence(timeout: 20), "The interface choice must survive relaunch")
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        chooseInterface("Current", in: app)
        XCTAssertFalse(menuButton("chat", in: app).exists)
        XCTAssertTrue((field.value as? String)?.contains(draft) == true)
        capture(app, "current-home-restored")
    }

    func testMenuRoutesKeepDraftAndHideForKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "light"]
        app.launch()
        XCTAssertTrue(menuButton("chat", in: app).waitForExistence(timeout: 20))
        let picker = app.segmentedControls["home.experimentalMenu"]
        XCTAssertGreaterThanOrEqual(picker.frame.width, app.windows.firstMatch.frame.width - 40)
        XCTAssertGreaterThanOrEqual(picker.frame.height, 50)
        let field = app.descendants(matching: .any)["composer.text"]
        field.tap()
        field.typeText(" Menu route draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for name in ["chat", "today", "goals", "feed", "library"] {
            XCTAssertFalse(menuButton(name, in: app).exists)
        }
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-keyboard")

        app.terminate()
        app.launch()
        XCTAssertTrue(menuButton("chat", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue((field.value as? String)?.contains("Menu route draft") == true)

        XCTAssertTrue(app.buttons["Today options"].waitForExistence(timeout: 10))
        for name in ["today", "goals", "feed", "library", "chat"] {
            menuButton(name, in: app).tap()
            XCTAssertTrue(menuButton(name, in: app).waitForExistence(timeout: 5))
            XCTAssertTrue(menuButton(name, in: app).isSelected)
            for other in ["chat", "today", "goals", "feed", "library"] {
                XCTAssertTrue(menuButton(other, in: app).isHittable)
            }
            switch name {
            case "goals": XCTAssertTrue(app.buttons["goals.add"].waitForExistence(timeout: 5))
            case "feed": XCTAssertTrue(app.navigationBars["Feed"].waitForExistence(timeout: 5))
            case "library": XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
            default: XCTAssertTrue(app.buttons["Today options"].waitForExistence(timeout: 5))
            }
            capture(app, "experimental-section-\(name)")
        }
        XCTAssertTrue((field.value as? String)?.contains("Menu route draft") == true)
    }

    func testDeveloperGateAndLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-visualReview", "-alice.developerMode", "NO", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(menuButton("chat", in: app).exists, "Developer mode must gate the experiment")
        app.buttons["chat.leading"].tap()
        app.buttons["sidebar.settings"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Interface"].exists)
        app.terminate()

        app.launchArguments = ["-visualReview", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental", "-alice.theme", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(menuButton("chat", in: app).waitForExistence(timeout: 20))
        capture(app, "experimental-home-dark-large-text")
        app.descendants(matching: .any)["composer.text"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(menuButton("chat", in: app).exists)
        XCTAssertTrue(app.buttons["composer.action"].isHittable)
        capture(app, "experimental-home-dark-large-keyboard")
        app.terminate()
        app.launch()
        XCTAssertTrue(menuButton("chat", in: app).waitForExistence(timeout: 20))
        for name in ["chat", "today", "goals", "feed", "library"] {
            XCTAssertTrue(menuButton(name, in: app).isHittable)
        }
        menuButton("feed", in: app).tap()
        XCTAssertTrue(app.navigationBars["Feed"].waitForExistence(timeout: 10))
        app.terminate()

        app.launchArguments = ["-seedLongBotChat", "-alice.developerMode", "YES", "-alice.developer.homeInterface", "experimental"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 20))
        XCTAssertFalse(menuButton("chat", in: app).exists, "Agent chats retain their existing composer")
    }

    private func menuButton(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.segmentedControls["home.experimentalMenu"].buttons[name.capitalized]
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
