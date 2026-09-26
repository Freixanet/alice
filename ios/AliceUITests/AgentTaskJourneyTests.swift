import XCTest

@MainActor
final class AgentTaskJourneyTests: XCTestCase {
    func testNewAgentStartsCleanAndRemainsReachableInRecents() {
        let app = XCUIApplication()
        app.launchArguments += ["-seedAgentMaker", "-alice.theme", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 20))
        app.buttons["Add"].tap()
        app.buttons["New Agent"].tap()
        XCTAssertTrue(app.buttons["composer.action"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Respuesta de prueba 30."].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "alice-new-agent-independent-task-dark"
        capture.lifetime = .keepAlways
        add(capture)
        // Return through the same public drawer used by every conversation.
        app.buttons["chat.leading"].tap()
        XCTAssertTrue(app.buttons["sidebar.settings"].waitForExistence(timeout: 5))
        let task = app.buttons.containing(.staticText, identifier: "New Agent").firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        XCTAssertTrue(app.buttons["composer.action"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Respuesta de prueba 30."].exists)
    }
}
