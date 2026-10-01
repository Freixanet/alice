import XCTest

@MainActor
final class PurchaseReviewTests: XCTestCase {
    func testFormatsUnitsAndSecureAccessInLight() { review(theme: "light", large: false) }
    func testFormatsAndAccessInDarkWithLargeText() { review(theme: "dark", large: true) }

    private func review(theme: String, large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-purchaseReview", "-visualReview", "-alice.theme", theme]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Creapure 300 g")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        capture(app, "verified-formats-\(theme)")
        let next = app.buttons["Siguiente"]
        if !next.isHittable { app.swipeUp() }
        next.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Creapure 250 g")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Anterior"].tap()
        first.tap()
        let units = app.steppers["purchase.quantity"]
        for _ in 0..<3 where !units.isHittable { app.swipeUp() }
        XCTAssertTrue(units.waitForExistence(timeout: 5))
        capture(app, "format-detail-units-\(theme)")
        if !large {
            units.buttons.element(boundBy: 1).tap()
            app.buttons["Comprar con Alice"].tap()
            XCTAssertTrue(app.staticTexts["300 g · 2 unidades"].waitForExistence(timeout: 5))
        } else {
            let close = app.buttons["Cerrar"]
            if !close.isHittable { app.swipeDown() }
            close.tap()
        }
        let access = app.buttons["Continuar de forma segura"]
        for _ in 0..<4 where !access.isHittable { app.swipeUp() }
        XCTAssertTrue(access.isHittable)
        capture(app, "needs-login-card-\(theme)")
        access.tap()
        XCTAssertTrue(app.buttons["Create one"].waitForExistence(timeout: 5))
        app.buttons["Create one"].tap()
        XCTAssertTrue(app.textFields["Email for the new account"].exists)
        capture(app, "secure-account-choice-\(theme)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "purchase-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
