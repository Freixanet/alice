import XCTest

/// The purchase, from the person's side of the screen, against the purchase simulator's dashboard
/// (`hermes-plugin/qa/serve.py`, started by the `qa-ios` job of `.github/workflows/qa.yml`).
///
/// The server does the chat part (search, verified cards, the tap) and runs the errand; this test
/// is the person: it opens the errand in the app, approves the exact total, accepts a new price,
/// and confirms the order arrives — each answer travelling through the plugin's real routes. The
/// server's oracle checks the invariants after every event; the job fails on any finding.
/// Skipped when no QA server answers (an ordinary UI run).
@MainActor
final class PurchaseJourneyTests: XCTestCase {
    private var base: String { ProcessInfo.processInfo.environment["ALICE_QA_DASHBOARD"] ?? "http://localhost:8765" }
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        do {
            _ = try await call("GET", "/health")
        } catch {
            throw XCTSkip("No QA server at \(base): this journey runs in the qa-ios CI job.")
        }
    }

    func testAPurchaseIsApprovedFromTheAppAndANewPriceIsAcceptedFromItToo() async throws {
        // 1. The ordinary purchase: the errand waits for the person, who approves the exact total.
        let first = try await call("POST", "/qa/start", ["shop": "tienda-tres.example", "faults": []])
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")
        app = XCUIApplication()
        app.launchArguments = ["-qaDashboard", base, "-alice.theme", "light"]
        app.launch()
        open(row: "Zapatillas")
        capture("1-checkout-to-approve")
        tapContaining("Permitir", within: 30)
        waitFor(["Pedido realizado", "Pedido hecho"], within: 60)
        capture("2-order-placed")
        close()

        // 2. The shop charges another price in the basket: the errand stops, says it, and the person
        //    accepts it from the card; then approves the new total.
        let second = try await call("POST", "/qa/start", ["shop": "tienda-uno.example", "faults": ["price_changed"]])
        XCTAssertEqual(second["ok"] as? Bool, true, "\(second)")
        open(row: "Creatina")
        waitFor(["Comprarla a"], within: 60)
        capture("3-new-price")
        tapContaining("Comprarla a", within: 10)
        tapContaining("Permitir", within: 60)
        capture("4-new-total-to-approve")
        waitFor(["Pedido realizado", "Pedido hecho"], within: 60)
        capture("5-order-placed")
        close()

        // What the server's oracle saw, said here too so the failure names it.
        let state = try await call("GET", "/qa/state")
        let findings = state["findings"] as? [[String: Any]] ?? []
        XCTAssertTrue(findings.isEmpty, "the oracle found: \(findings)")
    }

    // MARK: - Driving the app

    private func open(row text: String) {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 45), "no errand row containing «\(text)»")
        row.tap()
    }

    private func tap(_ label: String, within seconds: TimeInterval) {
        let button = app.buttons[label]
        XCTAssertTrue(reach(button, within: seconds), "no «\(label)» button")
        for _ in 0..<4 where !button.isHittable { app.scrollViews.firstMatch.swipeUp() }
        button.tap()
    }

    private func tapContaining(_ text: String, within seconds: TimeInterval) {
        let button = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(reach(button, within: seconds), "no button containing «\(text)»")
        for _ in 0..<4 where !button.isHittable { app.scrollViews.firstMatch.swipeUp() }
        button.tap()
    }

    /// The card lists the order before its buttons, so «Permitir» can be below the fold, where
    /// SwiftUI has not built it yet: scroll while waiting.
    private func reach(_ element: XCUIElement, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if element.waitForExistence(timeout: 2) { return true }
            (app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app).swipeUp()
        }
        if element.exists { return true }
        // What the screen offered instead, so a failure names the real label.
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
        return false
    }

    private func waitFor(_ texts: [String], within seconds: TimeInterval) {
        let predicate = NSPredicate(format: texts.map { _ in "label CONTAINS %@" }.joined(separator: " OR "), argumentArray: texts)
        let any = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(any.waitForExistence(timeout: seconds), "none of \(texts) appeared")
    }

    private func close() {
        app.swipeDown(velocity: .fast)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "purchase-journey-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The QA server

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.timeoutInterval = 150
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
