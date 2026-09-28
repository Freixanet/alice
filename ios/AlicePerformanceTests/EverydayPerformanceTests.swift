import XCTest

/// Offline simulator baselines. These measure a fixed journey, not network/model
/// latency or physical-device battery use. Kept out of the normal quality suite.
@MainActor
final class EverydayPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var samples: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    private func application(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [fixture, "-alice.theme", "light"]
        return app
    }

    func testLaunchUntilResponsiveWithLongChat() {
        let app = application("-seedTallBotChat")
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: samples) {
            app.launch()
        }
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testScrollLongChatAndReturnToLatest() {
        let app = application("-seedTallBotChat")
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 15))
        let latest = app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "elementType == %d OR elementType == %d",
                        XCUIElement.ElementType.staticText.rawValue, XCUIElement.ElementType.textView.rawValue),
            NSPredicate(format: "label BEGINSWITH %@", "Titular de prueba 30.14"),
        ])).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: samples) {
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
            let jump = app.buttons["chat.scrollToBottom"]
            XCTAssertTrue(jump.waitForExistence(timeout: 5))
            jump.tap()
            XCTAssertTrue(latest.waitForExistence(timeout: 5))
            XCTAssertTrue(latest.frame.intersects(app.windows.firstMatch.frame))
        }
        app.terminate()
    }

    func testOpenAgentsAndReturnToChat() {
        let app = application("-visualReview")
        app.launch()
        XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 15))
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: samples) {
            app.buttons["chat.leading"].tap()
            app.buttons["sidebar.row.Agents"].tap()
            XCTAssertTrue(app.buttons["bots.back"].waitForExistence(timeout: 5))
            app.buttons["bots.back"].tap()
            XCTAssertTrue(app.buttons["chat.leading"].waitForExistence(timeout: 5))
        }
        app.terminate()
    }
}
